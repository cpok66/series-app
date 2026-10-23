import UIKit
import AVFoundation
import AVKit
import MediaPlayer

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate, AVPictureInPictureControllerDelegate {
    private var playlist: [DownloadedEpisode]
    private var index: Int
    private var current: DownloadedEpisode { playlist[index] }

    private let player = AVPlayer()
    private let videoView = PlayerLayerView()
    private var pip: AVPictureInPictureController?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []

    private var didResume = false
    private var lastSave = Date.distantPast
    private var isScrubbing = false
    private var locked = false
    private var speed: Float = 1
    private var hideTimer: Timer?
    private var hudWork: DispatchWorkItem?
    private var unlockWork: DispatchWorkItem?
    private var watchedThisSession = Set<String>()
    private var closed = false

    // Жесты громкости и яркости
    private var panActive = false
    private var panIsVolume = true
    private var panStartValue: Float = 0
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 10, height: 10))
    private var volumeSlider: UISlider? { volumeView.subviews.compactMap { $0 as? UISlider }.first }

    // Интерфейс
    private let controls = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let tracksButton = UIButton(type: .system)
    private let gravityButton = UIButton(type: .system)
    private let pipButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let remainLabel = UILabel()
    private let nextButton = UIButton(type: .system)
    private let skipIntroButton = UIButton(type: .system)
    private let unlockButton = UIButton(type: .system)
    private let hudLabel = UILabel()

    init(playlist: [DownloadedEpisode], index: Int) {
        self.playlist = playlist
        self.index = index
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Жизненный цикл

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoView.playerLayer.player = player
        videoView.playerLayer.videoGravity = .resizeAspect
        view.addSubview(videoView)
        view.addSubview(volumeView)

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        setupControls()
        setupGestures()
        setupPiP()
        observePlayer()
        load(index: index)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationLock.set(.landscape)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        OrientationLock.set(.portrait)
    }

    // MARK: - Загрузка серии

    private func load(index newIndex: Int) {
        saveProgress()
        index = newIndex
        let ep = current
        let item = AVPlayerItem(url: LocalStore.shared.fileURL(for: ep))
        didResume = false

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async { self?.itemReady(item) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemEnded() }
        }

        player.replaceCurrentItem(with: item)
        player.defaultRate = speed
        player.play()

        var title = "\(ep.showTitle) · \(ep.code)"
        if !ep.title.isEmpty { title += " · \(ep.title)" }
        titleLabel.text = title
        nextButton.isHidden = index + 1 >= playlist.count
        tracksButton.isHidden = true
        slider.value = 0
        timeLabel.text = "0:00"
        remainLabel.text = "-0:00"
        updateMoreMenu()
        showControls()
    }

    private func itemReady(_ item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        if !didResume {
            didResume = true
            if let st = LocalStore.shared.playback[current.id], !st.watched, st.position > 10 {
                let duration = item.duration.seconds
                if !duration.isFinite || st.position < duration - 30 {
                    player.seek(to: CMTime(seconds: st.position, preferredTimescale: 600))
                    showHUD("Продолжаем с \(Format.time(st.position))")
                }
            }
        }
        Task { await buildTracksMenu(for: item) }
    }

    private func itemEnded() {
        if let d = player.currentItem?.duration.seconds, d.isFinite {
            LocalStore.shared.updateProgress(id: current.id, position: d, duration: d)
        }
        watchedThisSession.insert(current.id)
        if AppSettings.shared.autoNext, index + 1 < playlist.count {
            load(index: index + 1)
            showHUD("Следующая серия")
        } else {
            updatePlayButton()
            showControls()
        }
    }

    // MARK: - Наблюдение за плеером

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updatePlayButton() }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: UIApplication.willResignActiveNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveProgress()
                LocalStore.shared.saveNow()
            }
        })
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        let d = item.duration.seconds
        guard t.isFinite else { return }
        if d.isFinite, d > 0 {
            if !isScrubbing {
                slider.value = Float(t / d)
                timeLabel.text = Format.time(t)
                remainLabel.text = "-" + Format.time(d - t)
            }
            if Date().timeIntervalSince(lastSave) > 5 { saveProgress() }
        }
        updateSkipIntro(at: t)
    }

    private func saveProgress() {
        lastSave = Date()
        guard let item = player.currentItem else { return }
        let t = player.currentTime().seconds
        let d = item.duration.seconds
        guard t.isFinite, d.isFinite, d > 0, t > 1 else { return }
        LocalStore.shared.updateProgress(id: current.id, position: t, duration: d)
        if t / d >= 0.9 { watchedThisSession.insert(current.id) }
    }

    // MARK: - Интерфейс

    private func symbol(_ b: UIButton, _ name: String, size: CGFloat = 20) {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        b.setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        b.tintColor = .white
    }

    private func setupControls() {
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        view.addSubview(controls)

        symbol(closeButton, "xmark")
        symbol(tracksButton, "captions.bubble")
        symbol(gravityButton, "arrow.up.left.and.arrow.down.right")
        symbol(pipButton, "pip.enter")
        symbol(lockButton, "lock.open")
        symbol(moreButton, "ellipsis.circle")
        symbol(backButton, "gobackward.10", size: 30)
        symbol(playButton, "pause.fill", size: 44)
        symbol(forwardButton, "goforward.10", size: 30)
        symbol(nextButton, "forward.end.fill")

        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        gravityButton.addTarget(self, action: #selector(toggleGravity), for: .touchUpInside)
        pipButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        lockButton.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)
        backButton.addTarget(self, action: #selector(seekBack), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(seekForward), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(playNext), for: .touchUpInside)
        tracksButton.showsMenuAsPrimaryAction = true
        moreButton.showsMenuAsPrimaryAction = true

        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topBar = UIStackView(arrangedSubviews: [closeButton, titleLabel, tracksButton, gravityButton, pipButton, lockButton, moreButton])
        topBar.axis = .horizontal
        topBar.spacing = 20
        topBar.alignment = .center

        let center = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        center.axis = .horizontal
        center.spacing = 56
        center.alignment = .center

        for label in [timeLabel, remainLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        slider.minimumTrackTintColor = .systemOrange
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.setThumbImage(Self.thumbImage(), for: .normal)
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let bottomBar = UIStackView(arrangedSubviews: [timeLabel, slider, remainLabel, nextButton])
        bottomBar.axis = .horizontal
        bottomBar.spacing = 14
        bottomBar.alignment = .center

        for v in [topBar, center, bottomBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(v)
        }
        let guide = controls.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            center.centerXAnchor.constraint(equalTo: controls.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
        ])

        // Кнопка пропуска заставки видна и при скрытом интерфейсе
        var config = UIButton.Configuration.filled()
        config.title = "Пропустить заставку"
        config.image = UIImage(systemName: "forward.fill")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.white.withAlphaComponent(0.9)
        config.baseForegroundColor = .black
        skipIntroButton.configuration = config
        skipIntroButton.isHidden = true
        skipIntroButton.addTarget(self, action: #selector(skipIntro), for: .touchUpInside)

        var unlockConfig = UIButton.Configuration.filled()
        unlockConfig.image = UIImage(systemName: "lock.fill")
        unlockConfig.title = "Разблокировать"
        unlockConfig.imagePadding = 8
        unlockConfig.cornerStyle = .capsule
        unlockConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
        unlockConfig.baseForegroundColor = .white
        unlockButton.configuration = unlockConfig
        unlockButton.isHidden = true
        unlockButton.addTarget(self, action: #selector(toggleLock), for: .touchUpInside)

        hudLabel.textColor = .white
        hudLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        hudLabel.textAlignment = .center
        hudLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        hudLabel.layer.cornerRadius = 10
        hudLabel.clipsToBounds = true
        hudLabel.alpha = 0

        for v in [skipIntroButton, unlockButton, hudLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let vg = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            skipIntroButton.trailingAnchor.constraint(equalTo: vg.trailingAnchor, constant: -24),
            skipIntroButton.bottomAnchor.constraint(equalTo: vg.bottomAnchor, constant: -64),
            unlockButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unlockButton.topAnchor.constraint(equalTo: vg.topAnchor, constant: 20),
            hudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudLabel.topAnchor.constraint(equalTo: vg.topAnchor, constant: 64),
            hudLabel.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private static func thumbImage() -> UIImage {
        let size = CGSize(width: 14, height: 14)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
        }
    }

    private func updatePlayButton() {
        let playing = player.timeControlStatus != .paused
        symbol(playButton, playing ? "pause.fill" : "play.fill", size: 44)
        if playing { scheduleHide() }
    }

    private func showControls() {
        guard !locked else { return }
        controls.isHidden = false
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        scheduleHide()
    }

    private func hideControls() {
        hideTimer?.invalidate()
        UIView.animate(withDuration: 0.25) { self.controls.alpha = 0 }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.timeControlStatus != .paused, !self.isScrubbing else { return }
                self.hideControls()
            }
        }
    }

    private func showHUD(_ text: String) {
        hudLabel.text = "   \(text)   "
        hudWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.hudLabel.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.hudLabel.alpha = 0 }
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Дорожки и меню

    private func buildTracksMenu(for item: AVPlayerItem) async {
        let asset = item.asset
        var sections: [UIMenuElement] = []

        if let audio = try? await asset.loadMediaSelectionGroup(for: .audible), audio.options.count > 1 {
            let selected = item.currentMediaSelection.selectedMediaOption(in: audio)
            let actions = audio.options.map { option in
                UIAction(title: option.displayName, state: option == selected ? .on : .off) { [weak self] _ in
                    item.select(option, in: audio)
                    self?.refreshTracksMenu()
                }
            }
            sections.append(UIMenu(title: "Озвучка", options: .displayInline, children: actions))
        }

        if let subs = try? await asset.loadMediaSelectionGroup(for: .legible), !subs.options.isEmpty {
            let selected = item.currentMediaSelection.selectedMediaOption(in: subs)
            var actions = [UIAction(title: "Выключены", state: selected == nil ? .on : .off) { [weak self] _ in
                item.select(nil, in: subs)
                self?.refreshTracksMenu()
            }]
            actions += subs.options.map { option in
                UIAction(title: option.displayName, state: option == selected ? .on : .off) { [weak self] _ in
                    item.select(option, in: subs)
                    self?.refreshTracksMenu()
                }
            }
            sections.append(UIMenu(title: "Субтитры", options: .displayInline, children: actions))
        }

        guard item === player.currentItem else { return }
        tracksButton.menu = UIMenu(children: sections)
        tracksButton.isHidden = sections.isEmpty
    }

    private func refreshTracksMenu() {
        guard let item = player.currentItem else { return }
        Task { await buildTracksMenu(for: item) }
    }

    private func updateMoreMenu() {
        let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]
        let speedActions = speeds.map { s in
            UIAction(title: s == 1 ? "Обычная" : String(format: "%gx", s), state: s == speed ? .on : .off) { [weak self] _ in
                self?.setSpeed(s)
            }
        }
        let prefs = LocalStore.shared.prefs(showId: current.showId)
        var introItems: [UIMenuElement] = [
            UIAction(title: "Заставка начинается здесь", image: UIImage(systemName: "arrow.right.to.line")) { [weak self] _ in
                self?.markIntro(start: true)
            },
            UIAction(title: "Заставка заканчивается здесь", image: UIImage(systemName: "arrow.left.to.line")) { [weak self] _ in
                self?.markIntro(start: false)
            },
        ]
        if prefs.hasIntro {
            introItems.append(UIAction(title: "Сбросить заставку (\(Format.time(prefs.introStart))–\(Format.time(prefs.introEnd)))",
                                       image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                LocalStore.shared.setPrefs(ShowPrefs(), showId: self.current.showId)
                self.updateMoreMenu()
                self.showHUD("Заставка сброшена")
            })
        }
        let watched = LocalStore.shared.playback[current.id]?.watched == true
        let watchedAction = UIAction(title: watched ? "Отметить как непросмотренную" : "Отметить как просмотренную",
                                     image: UIImage(systemName: watched ? "eye.slash" : "eye")) { [weak self] _ in
            guard let self else { return }
            LocalStore.shared.setWatched(self.current.id, !watched)
            self.updateMoreMenu()
        }
        moreButton.menu = UIMenu(children: [
            UIMenu(title: "Скорость", image: UIImage(systemName: "speedometer"), children: speedActions),
            UIMenu(title: "Заставка", options: .displayInline, children: introItems),
            watchedAction,
        ])
    }

    private func setSpeed(_ s: Float) {
        speed = s
        player.defaultRate = s
        if player.timeControlStatus != .paused { player.rate = s }
        updateMoreMenu()
        showHUD(s == 1 ? "Обычная скорость" : String(format: "Скорость %gx", s))
    }

    private func markIntro(start: Bool) {
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        var prefs = LocalStore.shared.prefs(showId: current.showId)
        if start {
            prefs.introStart = t
            if prefs.introEnd <= t { prefs.introEnd = t + 90 }
            showHUD("Начало заставки: \(Format.time(t))")
        } else {
            prefs.introEnd = t
            if prefs.introStart >= t { prefs.introStart = max(0, t - 90) }
            showHUD("Конец заставки: \(Format.time(t))")
        }
        LocalStore.shared.setPrefs(prefs, showId: current.showId)
        updateMoreMenu()
    }

    private func updateSkipIntro(at t: Double) {
        let prefs = LocalStore.shared.prefs(showId: current.showId)
        let visible = prefs.hasIntro && t >= prefs.introStart && t < prefs.introEnd - 1 && !locked
        if skipIntroButton.isHidden == visible { skipIntroButton.isHidden = !visible }
    }

    // MARK: - Действия

    @objc private func close() {
        guard !closed else { return }
        closed = true
        saveProgress()
        player.pause()
        if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
        hideTimer?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        statusObservation = nil
        rateObservation = nil
        let toDelete = AppSettings.shared.deleteWatched ? watchedThisSession : []
        LocalStore.shared.saveNow()
        dismiss(animated: true) {
            toDelete.forEach { LocalStore.shared.removeDownloaded($0) }
        }
    }

    @objc private func togglePlay() {
        if player.timeControlStatus == .paused {
            if let item = player.currentItem, item.duration.isNumeric,
               player.currentTime().seconds >= item.duration.seconds - 0.5 {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
        showControls()
    }

    @objc private func seekBack() { seek(by: -10); showControls() }
    @objc private func seekForward() { seek(by: 10); showControls() }

    private func seek(by delta: Double) {
        let t = player.currentTime().seconds
        guard t.isFinite else { return }
        seek(to: t + delta)
    }

    private func seek(to seconds: Double) {
        var target = max(0, seconds)
        if let d = player.currentItem?.duration.seconds, d.isFinite { target = min(target, max(0, d - 1)) }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func playNext() {
        guard index + 1 < playlist.count else { return }
        load(index: index + 1)
    }

    @objc private func skipIntro() {
        seek(to: LocalStore.shared.prefs(showId: current.showId).introEnd)
        skipIntroButton.isHidden = true
    }

    @objc private func toggleGravity() {
        let layer = videoView.playerLayer
        let fill = layer.videoGravity == .resizeAspect
        layer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        symbol(gravityButton, fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        showHUD(fill ? "Во весь экран" : "Целиком")
        showControls()
    }

    @objc private func toggleLock() {
        locked.toggle()
        if locked {
            hideControls()
            symbol(lockButton, "lock.fill")
            skipIntroButton.isHidden = true
            flashUnlockButton()
        } else {
            unlockWork?.cancel()
            unlockButton.isHidden = true
            symbol(lockButton, "lock.open")
            showControls()
        }
    }

    private func flashUnlockButton() {
        unlockButton.isHidden = false
        unlockWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.unlockButton.isHidden = true }
        unlockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubChanged() {
        guard let d = player.currentItem?.duration.seconds, d.isFinite else { return }
        let t = Double(slider.value) * d
        timeLabel.text = Format.time(t)
        remainLabel.text = "-" + Format.time(d - t)
    }

    @objc private func scrubEnded() {
        if let d = player.currentItem?.duration.seconds, d.isFinite {
            seek(to: Double(slider.value) * d)
        }
        isScrubbing = false
        scheduleHide()
    }

    // MARK: - Жесты

    private func setupGestures() {
        let single = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        for g in [single, double, pan] as [UIGestureRecognizer] {
            g.delegate = self
            view.addGestureRecognizer(g)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var v = touch.view
        while let current = v {
            if current is UIControl { return false }
            v = current.superview
        }
        return true
    }

    @objc private func handleTap() {
        if locked { flashUnlockButton(); return }
        if controls.alpha > 0.5 { hideControls() } else { showControls() }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard !locked else { flashUnlockButton(); return }
        let x = g.location(in: view).x
        let w = view.bounds.width
        if x < w / 3 {
            seek(by: -10); showHUD("−10 сек")
        } else if x > w * 2 / 3 {
            seek(by: 10); showHUD("+10 сек")
        } else {
            togglePlay()
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard !locked else { return }
        switch g.state {
        case .began:
            let v = g.velocity(in: view)
            panActive = abs(v.y) > abs(v.x)
            guard panActive else { return }
            panIsVolume = g.location(in: view).x > view.bounds.width / 2
            if panIsVolume {
                panStartValue = volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
            } else {
                panStartValue = Float(view.window?.windowScene?.screen.brightness ?? 0.5)
            }
        case .changed:
            guard panActive else { return }
            let dy = -g.translation(in: view).y / max(1, view.bounds.height * 0.8)
            let value = max(0, min(1, panStartValue + Float(dy)))
            if panIsVolume {
                volumeSlider?.value = value
                showHUD("Громкость \(Int(value * 100))%")
            } else {
                view.window?.windowScene?.screen.brightness = CGFloat(value)
                showHUD("Яркость \(Int(value * 100))%")
            }
        default:
            panActive = false
        }
    }

    // MARK: - Картинка в картинке

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            pipButton.isHidden = true
            return
        }
        pip = AVPictureInPictureController(playerLayer: videoView.playerLayer)
        pip?.delegate = self
        pip?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    @objc private func togglePiP() {
        guard let pip else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
