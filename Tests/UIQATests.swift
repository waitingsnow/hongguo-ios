import XCTest

@MainActor
final class HongguoQATests: XCTestCase {
    /// Explicit anonymous real playback; run only on a task simulator.
    func testV5PlaybackAndEpisodeSwitching() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-autoNext", "NO"]
        app.launch()
        openFirstEpisode(in: app, search: "无限白粥")
        assertPlayback("播放中", in: app)
        capture("v5-first-episode")
        let video = app.buttons["视频画面"]
        let point = video.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.5))
        point.doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)
        point.doubleTap()
        assertPlayback("播放中", in: app, timeout: 10)
        let holdStart = video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
        let lockTarget = video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
        holdStart.press(forDuration: 0.65, thenDragTo: lockTarget, withVelocity: .slow, thenHoldForDuration: 0.15)
        assertPlayback("已锁定 2 倍速", in: app, timeout: 5)
        app.buttons["player.speedUnlock"].tap()
        assertPlayback("播放中", in: app, timeout: 5)
        video.swipeUp()
        assertEpisode(2, in: app)
        assertPlayback("播放中", in: app)
        capture("v5-second-episode")
        video.swipeDown()
        assertEpisode(1, in: app)
        assertPlayback("播放中", in: app)
        app.buttons["关闭播放器"].tap()
    }

    /// Search entry above 今日推荐, the 刷剧 feed, 清晰度 and the saved home list. Anonymous live catalogue only.
    func testHomeSearchFeedModeAndQuality() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "warm", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-quality", "1080p", "-autoNext", "NO"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.featured.")).firstMatch.waitForExistence(timeout: 60))
        // The search bar sits just above 今日推荐; a tap on it must open search, not the featured drama.
        app.buttons["搜索短剧"].tap()
        XCTAssertTrue(app.textFields["搜索剧名或关键词"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["剧集详情"].exists)
        capture("home-search-entry")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["home.feedMode"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["immersive_feed"].waitForExistence(timeout: 15))
        let playFull = app.buttons["immersive_play_0"]
        XCTAssertTrue(playFull.wait(for: \.label, toEqual: "看全集", timeout: 30))
        capture("home-feed-mode")
        playFull.tap()
        assertPlayback("播放中", in: app)
        let done = openPlayerMore(in: app)
        assertPlayerChoice("1080P", in: app)
        let lowerQuality = app.buttons["720P"]
        XCTAssertTrue(lowerQuality.wait(for: \.isHittable, toEqual: true, timeout: 5))
        lowerQuality.tap()
        assertPlayerChoice("720P", in: app)
        XCTAssertTrue(done.isHittable)
        capture("player-quality-720")
        closePlayerMore(done)
        assertPlayback("播放中", in: app)
        let reopened = openPlayerMore(in: app)
        assertPlayerChoice("720P", in: app)
        closePlayerMore(reopened)
        app.buttons["关闭播放器"].tap()
        XCTAssertTrue(app.buttons["immersive_exit"].waitForExistence(timeout: 10)); app.buttons["immersive_exit"].tap()
        XCTAssertTrue(app.buttons["home.feedMode"].waitForExistence(timeout: 10))
        // A relaunch paints the saved home list without waiting for the network.
        app.terminate(); app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.featured.")).firstMatch.waitForExistence(timeout: 3))
    }

    /// Anonymous live catalogue only, using a task-specific simulator with no personal account.
    func testHomeSectionsDoNotRepeat() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        func ids(_ prefix: String) -> Set<String> {
            Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
                .allElementsBoundByIndex.map { String($0.identifier.dropFirst(prefix.count)) })
        }
        for (theme, prefix) in [("warm", "home.featured."), ("cards", "home.ranking.")] {
            app.launchArguments = ["-theme", theme, "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: 60))
            let featuredIDs = ids(prefix)
            XCTAssertFalse(featuredIDs.isEmpty)
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.grid.")).firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(featuredIDs.intersection(ids("home.grid.")).isEmpty, "Featured recommendations must not repeat in the poster grid")
            capture("home-\(theme)-unique-sections")
            app.terminate()
        }
    }

    func testUpdateSourcesAndVersion() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launch()
        if app.buttons["开始发现好故事"].waitForExistence(timeout: 10) { app.buttons["开始发现好故事"].tap() }
        XCTAssertTrue(app.tabBars.buttons["我的"].waitForExistence(timeout: 10))
        app.tabBars.buttons["我的"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "下载新版本与全能签在线源")).firstMatch.tap()
        XCTAssertTrue(app.buttons["updates.check"].waitForExistence(timeout: 5))
        capture("16a-update-version")
        XCTAssertNotNil(app.debugDescription.range(of: #"\d+\.\d+\.\d+\s*[（(]\d+[）)]"#, options: .regularExpression))
        XCTAssertFalse(app.buttons["updates.export"].exists)
        app.buttons["updates.route"].tap()
        app.buttons["官方 GitHub"].tap()
        for (identifier, title) in [("github", "官方 GitHub"), ("gh-proxy", "gh-proxy"), ("ghfast", "ghfast")] {
            let copy = app.buttons["updates.copy.\(identifier)"]
            if !copy.isHittable { app.swipeUp() }
            XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
            XCTAssertTrue(app.alerts["软件源"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.alerts.staticTexts["已复制\(title)软件源地址，可在全能签中手动添加。"].exists)
            app.alerts.buttons["好"].tap()
        }
        capture("16-update-sources")
    }

    func testRealNavigationAndPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-updates.checkOnLaunch", "NO", "-speed", "1", "-autoNext", "NO"]
        app.launch()
        if app.buttons["开始发现好故事"].waitForExistence(timeout: 10) {
            capture("01-theme-welcome"); app.buttons["开始发现好故事"].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 10))
        capture("02-home")
        let libraryTab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["片单", "追剧"])).firstMatch
        libraryTab.tap()
        XCTAssertTrue(app.staticTexts["本机记录"].waitForExistence(timeout: 5))
        capture("03-library")
        app.tabBars.buttons["我的"].tap(); capture("04-my")
        app.buttons["my.settings"].tap()
        app.staticTexts["主题样式"].tap(); capture("05-theme-settings")
        app.staticTexts["沉浸暗场"].tap()
        returnFromThemeSettings(in: app)
        app.tabBars.buttons["首页"].tap()
        let playFull = app.buttons["immersive_play_0"]
        XCTAssertTrue(playFull.wait(for: \.label, toEqual: "看全集", timeout: 35))
        capture("06-immersive-home")
        app.tabBars.buttons["剧场"].tap()
        XCTAssertTrue(app.buttons["搜索短剧"].waitForExistence(timeout: 10))
        capture("07-discover")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "筛选条件")).firstMatch.tap()
        capture("07b-filters"); app.buttons["查看结果"].tap()
        app.buttons["搜索短剧"].tap()
        let input = app.textFields["搜索剧名或关键词"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("王妈"); app.buttons["搜索"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "查看选集")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40))
        capture("08-search-results"); result.tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 10))
        waitForDetailPlaybackOptions(in: app)
        capture("09-detail")
        if app.buttons["本机收藏"].exists { app.buttons["本机收藏"].tap() }
        openFirstEpisodeFromDetail(in: app)
        XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 10))
        assertPlayback("播放中", in: app, timeout: 90)
        capture("10-player-live")
        let done = openPlayerMore(in: app)
        for label in ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"] {
            XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), label)
        }
        assertPlayerChoice("1×", in: app)
        let faster = app.buttons["1.5×"]
        XCTAssertTrue(faster.wait(for: \.isHittable, toEqual: true, timeout: 5))
        capture("11-speed-picker")
        faster.tap()
        assertPlayerChoice("1.5×", in: app)
        XCTAssertTrue(done.isHittable)
        closePlayerMore(done)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45)).press(forDuration: 0.7)
        let reopened = openPlayerMore(in: app)
        assertPlayerChoice("1.5×", in: app)
        closePlayerMore(reopened)
        app.buttons["视频画面"].swipeUp()
        assertEpisode(2, in: app)
        assertPlayback("播放中", in: app, timeout: 90)
        capture("12-player-next")
        app.buttons["视频画面"].swipeDown()
        assertEpisode(1, in: app)
        assertPlayback("播放中", in: app, timeout: 90)
        capture("12a-drag-previous")
        app.buttons["player.episodes"].tap()
        assertPlayerChoice("1", in: app)
        let thirdEpisode = app.buttons["3"]
        XCTAssertTrue(thirdEpisode.wait(for: \.isHittable, toEqual: true, timeout: 5))
        capture("12b-episode-picker"); thirdEpisode.tap()
        assertEpisode(3, in: app)
        assertPlayback("播放中", in: app, timeout: 90)
        let playedDrama = String(app.buttons["player.dramaTitle"].label.dropLast("，第 3 集".count))
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", playedDrama, "第 3 集 ·")).firstMatch
        capture("12c-third-episode")
        app.buttons["关闭播放器"].tap()
        app.tabBars.buttons["追剧"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        capture("13-library-history")
        app.tabBars.buttons["我的"].tap()
        app.buttons["my.settings"].tap()
        app.staticTexts["主题样式"].tap()
        XCTAssertTrue(app.staticTexts["内容卡片"].waitForExistence(timeout: 5))
        app.staticTexts["内容卡片"].tap()
        returnFromThemeSettings(in: app)
        app.tabBars.buttons["首页"].tap()
        capture("14-cards-home")
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["片单"].waitForExistence(timeout: 10))
        app.tabBars.buttons["片单"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        capture("15-library-after-relaunch")
    }

    /// Anonymous live playback on a task simulator.
    func testPlayerTapGestures() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-autoNext", "NO"]
        app.launch()
        openFirstEpisode(in: app, search: "无限白粥")
        assertPlayback("播放中", in: app, timeout: 90)
        let video = app.buttons["视频画面"]
        func point(_ x: CGFloat) -> XCUICoordinate { video.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)) }
        let progress = app.sliders["播放进度"]
        func percent() -> Double { Double((progress.value as? String ?? "0").filter { $0.isNumber || $0 == "." }) ?? 0 }
        point(0.5).doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)
        // No side skips: a double tap on either side also just plays or pauses.
        let start = percent()
        point(0.75).doubleTap()
        assertPlayback("播放中", in: app, timeout: 5)
        point(0.12).doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)
        XCTAssertLessThan(abs(percent() - start), 3, "side double taps do not jump")
        // A sideways swipe without holding never seeks; holding first and then dragging does.
        point(0.2).press(forDuration: 0.05, thenDragTo: point(0.8)); sleep(1)
        XCTAssertLessThan(abs(percent() - start), 3, "a quick sideways swipe does not seek")
        point(0.2).press(forDuration: 0.8, thenDragTo: point(0.7)); sleep(1)
        capture("20-hold-drag-seek")
        XCTAssertGreaterThan(percent(), start + 5, "holding and dragging right moves ahead")
        let episodePicker = app.buttons["player.episodes"]
        point(0.75).tap()
        XCTAssertTrue(episodePicker.wait(for: \.isHittable, toEqual: false, timeout: 5))
        capture("22-tap-hides")
        point(0.15).tap()
        XCTAssertTrue(episodePicker.wait(for: \.isHittable, toEqual: true, timeout: 5))
        point(0.27).doubleTap()
        assertPlayback("播放中", in: app, timeout: 5)
        app.buttons["player.dramaTitle"].tap()
        XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 5))
        capture("21-detail-over-player")
        app.buttons["完成"].tap()
        assertPlayback("播放中", in: app, timeout: 5)
    }

    func testPlayerMoreCleanScreenAndSleepTimer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_MODE"] == "--live",
                          "Set TEST_RUNNER_HONGGUO_QA_MODE=--live to run anonymous catalogue and playback checks.")
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let previousOrientation = device.orientation
        device.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        defer {
            app.terminate()
            device.orientation = previousOrientation
        }
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO",
                               "-speed", "1", "-autoNext", "NO"]
        app.launch()
        openFirstEpisode(in: app, search: "无限白粥")
        let picture = app.buttons["视频画面"]
        let video = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let finished = app.staticTexts["本集已播完，上滑观看下一集"]
        let startedOrFinished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picture.value as? String == "播放中" || finished.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [startedOrFinished], timeout: 60), .completed)
        if !finished.exists { video.doubleTap() }
        assertPlayback("已暂停", in: app, timeout: 5)

        let title = app.buttons["player.dramaTitle"]
        let episodes = app.buttons["player.episodes"]
        let more = app.buttons["player.more"]
        let progress = app.sliders["播放进度"]
        let overlays = [title, episodes, more, progress, app.buttons["player.favorite"],
                        app.buttons["discussion.toggle"].firstMatch, app.buttons["discussion.comments"].firstMatch]
        for overlay in overlays {
            XCTAssertTrue(overlay.wait(for: \.isHittable, toEqual: true, timeout: 5))
        }

        let done = openPlayerMore(in: app)
        assertPlayerChoice("1×", in: app)
        let faster = app.buttons["1.5×"]
        XCTAssertTrue(faster.wait(for: \.isHittable, toEqual: true, timeout: 5))
        faster.tap()
        assertPlayerChoice("1.5×", in: app)
        XCTAssertTrue(done.isHittable)
        capture("player-more-speed-1.5x")

        let cleanScreen = app.buttons["清屏播放"]
        revealMoreOption(cleanScreen, in: app)
        cleanScreen.tap()
        XCTAssertTrue(done.wait(for: \.exists, toEqual: false, timeout: 5))
        for overlay in overlays {
            XCTAssertTrue(overlay.wait(for: \.isHittable, toEqual: false, timeout: 5), overlay.identifier)
        }
        capture("player-more-clean-screen")
        video.tap()
        for overlay in overlays {
            XCTAssertTrue(overlay.wait(for: \.isHittable, toEqual: true, timeout: 5), overlay.identifier)
        }
        assertEpisode(1, in: app)

        let reopened = openPlayerMore(in: app)
        assertPlayerChoice("1.5×", in: app)
        let timer = app.buttons["定时关闭"]
        revealMoreOption(timer, in: app)
        for (choice, status) in [("播完本集", "本集结束后关闭"), ("30 分钟", "30 分钟后关闭"), ("关闭", "关闭")] {
            timer.tap()
            if choice == "播完本集" {
                for label in ["播完本集", "15 分钟", "30 分钟", "60 分钟", "关闭"] {
                    XCTAssertTrue(app.buttons[label].waitForExistence(timeout: 5), label)
                }
                capture("player-sleep-timer-options")
            }
            app.buttons[choice].tap()
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", status), object: timer)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        closePlayerMore(reopened)
        assertEpisode(1, in: app)
        XCTAssertTrue(episodes.wait(for: \.isHittable, toEqual: true, timeout: 5))
        episodes.tap()
        let picker = app.navigationBars["选集"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        assertPlayerChoice("1", in: app)
        let secondEpisode = app.buttons["2"]
        XCTAssertTrue(secondEpisode.wait(for: \.isHittable, toEqual: true, timeout: 5))
        capture("player-episode-picker")
        secondEpisode.tap()
        XCTAssertTrue(picker.wait(for: \.exists, toEqual: false, timeout: 5))
        assertEpisode(2, in: app)
        assertPlayback("播放中", in: app)
        XCTAssertTrue(app.staticTexts["第 2 集"].waitForExistence(timeout: 5))
        let initialProgress = progress.value as? String
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            progress.isEnabled && (progress.value as? String).map { $0 != initialProgress } == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 15), .completed)
        capture("player-episode-2-playing")
    }

    func testPlayerLandscapeLockAndEpisodeSwitching() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_MODE"] == "--live")
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let previousOrientation = device.orientation
        device.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        defer {
            app.terminate()
            device.orientation = previousOrientation
        }
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-autoNext", "NO"]
        app.launch()
        openFirstEpisode(in: app, search: "无限白粥")
        assertPlayback("播放中", in: app)
        let video = app.buttons["视频画面"]
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)

        device.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)

        let lock = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "player.lock", "锁定屏幕")).firstMatch
        let unlock = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "player.lock", "解锁屏幕")).firstMatch
        XCTAssertTrue(lock.wait(for: \.isHittable, toEqual: true, timeout: 5))
        let title = app.buttons["player.dramaTitle"]
        let episodeNumber = app.staticTexts["第 1 集"]
        let episodePicker = app.buttons["player.episodes"]
        let actions = [app.buttons["player.favorite"], app.buttons["discussion.toggle"].firstMatch,
                       app.buttons["discussion.comments"].firstMatch]
        XCTAssertTrue(title.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertTrue(episodeNumber.waitForExistence(timeout: 5))
        XCTAssertTrue(episodePicker.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertLessThan(title.frame.midX, app.frame.midX)
        XCTAssertLessThan(title.frame.midY, app.frame.midY)
        XCTAssertLessThan(episodeNumber.frame.midX, app.frame.midX)
        XCTAssertEqual(episodeNumber.frame.midY, title.frame.midY, accuracy: 12)
        XCTAssertGreaterThan(episodePicker.frame.midX, app.frame.midX)
        XCTAssertGreaterThan(episodePicker.frame.midY, app.frame.midY)
        for action in actions {
            XCTAssertTrue(action.wait(for: \.isHittable, toEqual: true, timeout: 5))
            XCTAssertLessThan(action.frame.midX, app.frame.midX)
            XCTAssertEqual(action.frame.midY, episodePicker.frame.midY, accuracy: 12)
        }
        for (left, right) in zip(actions, actions.dropFirst()) {
            XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX)
        }
        XCTAssertGreaterThan(lock.frame.midX, app.frame.minX + 0.75 * app.frame.width)
        XCTAssertEqual(lock.frame.midY, app.frame.midY, accuracy: 0.12 * app.frame.height)
        capture("player-landscape-controls")

        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.28))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.72))
        lower.press(forDuration: 0.05, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
        assertEpisode(2, in: app)
        assertPlayback("播放中", in: app)
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)

        XCTAssertTrue(lock.wait(for: \.isHittable, toEqual: true, timeout: 5))
        lock.tap()
        XCTAssertTrue(unlock.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertGreaterThan(unlock.frame.midX, app.frame.minX + 0.75 * app.frame.width)
        XCTAssertEqual(unlock.frame.midY, app.frame.midY, accuracy: 0.12 * app.frame.height)
        XCTAssertTrue(episodePicker.wait(for: \.isHittable, toEqual: false, timeout: 5))
        capture("player-landscape-locked")
        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(unlock.wait(for: \.exists, toEqual: false, timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(unlock.wait(for: \.isHittable, toEqual: true, timeout: 5))
        unlock.tap()
        assertEpisode(2, in: app)
        assertPlayback("已暂停", in: app, timeout: 5)

        upper.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        assertEpisode(1, in: app)
        assertPlayback("播放中", in: app)
        capture("player-landscape-unlocked-previous")
    }

    func testImmersiveHomeControlsPagingAndFirstEpisode() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_MODE"] == "--live",
                          "Set TEST_RUNNER_HONGGUO_QA_MODE=--live to run anonymous catalogue and playback checks.")
        continueAfterFailure = true
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO",
                               "-speed", "1.5", "-autoNext", "NO"]
        app.launch()

        let feed = app.scrollViews["immersive_feed"]
        let firstTitle = app.buttons["immersive_title_0"]
        let secondTitle = app.buttons["immersive_title_1"]
        let detailBar = app.navigationBars["剧集详情"]
        func visible(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
            element.wait(for: \.isHittable, toEqual: true, timeout: timeout)
        }
        func checkDetailAndReturn(title: String) {
            let opened = detailBar.waitForExistence(timeout: 8)
            XCTAssertTrue(opened, "Expected the detail page for \(title)")
            guard opened else { return }
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 8),
                          "The opened detail must show \(title)")
            detailBar.buttons.firstMatch.tap()
        }
        func lockAndUnlock(_ surface: XCUIElement, buttonID: String) {
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.60))
            let target = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.24))
            start.press(forDuration: 0.65, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.15)
            let unlock = app.buttons[buttonID]
            XCTAssertTrue(visible(unlock, timeout: 4), "The vertical hold must stay locked after release")
            if buttonID == "player.speedUnlock" {
                assertPlayback("已锁定 2 倍速", in: app, timeout: 4)
            }
            if unlock.isHittable { unlock.tap() }
            XCTAssertFalse(unlock.exists)
        }

        let loaded = visible(firstTitle, timeout: 60)
        XCTAssertTrue(loaded, "The anonymous home feed must show a first drama")
        guard loaded else { return }
        let firstName = firstTitle.label

        XCTContext.runActivity(named: "Full-width playback entry and right-side follow control") { _ in
            let play = app.buttons["immersive_play_0"]
            let favorite = app.buttons["immersive_favorite_0"]
            XCTAssertTrue(visible(play))
            XCTAssertTrue(visible(favorite))
            XCTAssertEqual(play.label, "看全集")
            XCTAssertTrue(["追剧", "已追"].contains(favorite.label))
            XCTAssertGreaterThan(play.frame.width, app.frame.width / 2)
            XCTAssertLessThan(favorite.frame.width, app.frame.width / 4)
            XCTAssertLessThanOrEqual(favorite.frame.maxY, play.frame.minY)
            XCTAssertEqual(favorite.frame.maxX, play.frame.maxX, accuracy: 4)
            XCTAssertEqual(firstTitle.frame.minX, play.frame.minX, accuracy: 4)
            XCTAssertFalse(app.staticTexts["上滑看下一部"].exists)
            XCTAssertFalse(app.buttons["选集"].exists)
            XCTAssertFalse(app.buttons["详情"].exists)
            capture("immersive-recommendation-actions")
        }

        XCTContext.runActivity(named: "Swipe up, tap the second title, and swipe down") { _ in
            feed.swipeUp()
            let next = visible(secondTitle)
            XCTAssertTrue(next, "An upward swipe must page to the second drama")
            guard next else { return }
            XCTAssertFalse(detailBar.exists)
            let secondName = secondTitle.label
            XCTAssertNotEqual(secondName, firstName)
            secondTitle.tap()
            checkDetailAndReturn(title: secondName)
            let restored = visible(secondTitle)
            XCTAssertTrue(restored, "Returning from details must keep the second page")
            guard restored else { return }
            feed.swipeDown()
            XCTAssertTrue(visible(firstTitle), "A downward swipe must return to the first drama")
            XCTAssertFalse(detailBar.exists)
        }

        guard visible(firstTitle) else { XCTFail("The first page is needed for the left swipe"); return }
        XCTContext.runActivity(named: "Swipe left to the first drama's detail") { _ in
            feed.swipeLeft()
            checkDetailAndReturn(title: firstName)
            XCTAssertTrue(visible(firstTitle), "Returning from details must keep the first page")
        }

        XCTContext.runActivity(named: "Play episode 1 from the 1.5× preview") { _ in
            let preview = app.buttons["预览视频"]
            XCTAssertTrue(visible(preview, timeout: 45), "Home should open a preview before entering playback")
            lockAndUnlock(preview, buttonID: "feed.speedUnlock")
            XCTAssertTrue(visible(firstTitle), "A vertical drag after holding must keep the same page")
            let play = app.buttons["immersive_play_0"]
            guard visible(play) else { XCTFail("The first drama is no longer available to play"); return }
            play.tap()
            let playerTitle = app.buttons["player.dramaTitle"]
            let opened = visible(playerTitle, timeout: 45)
            XCTAssertTrue(opened, "The play control must open the full player")
            guard opened else { return }
            XCTAssertEqual(playerTitle.label, "\(firstName)，第 1 集")
            assertPlayback("播放中", in: app)
            let done = openPlayerMore(in: app)
            assertPlayerChoice("1.5×", in: app)
            closePlayerMore(done)
            lockAndUnlock(app.buttons["视频画面"], buttonID: "player.speedUnlock")
            assertPlayback("播放中", in: app, timeout: 5)
            let reopened = openPlayerMore(in: app)
            assertPlayerChoice("1.5×", in: app)
            closePlayerMore(reopened)
            let progress = app.sliders["播放进度"]
            func progressPercent() -> Double? {
                guard let value = progress.value as? String else { return nil }
                return Double(value.filter { $0.isNumber || $0 == "." })
            }
            guard let initialValue = progressPercent() else { XCTFail("Playback progress is unavailable"); return }
            let advances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                progress.isEnabled && progressPercent().map { $0 > initialValue } == true
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 15), .completed, "Episode 1 must advance")
            XCTAssertEqual(playerTitle.label, "\(firstName)，第 1 集")
            capture("immersive-first-episode-1.5x")
        }
    }

    func testEpisodeCommentsAndDanmakuPreference() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_MODE"] == "--live")
        continueAfterFailure = false
        let previousOrientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = previousOrientation }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-speed", "1"]
        app.launch()

        func expectValue(_ value: String, of control: XCUIElement, line: UInt = #line) {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Expected \(value)", line: line)
        }
        let myTab = app.tabBars.buttons["我的"]
        XCTAssertTrue(myTab.wait(for: \.isHittable, toEqual: true, timeout: 10))
        myTab.tap()
        app.buttons["my.settings"].tap()
        let autoplayRow = app.switches["自动连播下一集"]
        XCTAssertTrue(autoplayRow.waitForExistence(timeout: 5))
        let nestedAutoplay = autoplayRow.switches.firstMatch
        let autoplay = nestedAutoplay.exists ? nestedAutoplay : autoplayRow
        XCTAssertTrue(autoplay.wait(for: \.isHittable, toEqual: true, timeout: 5))
        if autoplay.value as? String == "1" { autoplay.tap() }
        expectValue("0", of: autoplay)
        app.navigationBars["设置"].buttons.firstMatch.tap()

        openFirstEpisode(in: app, search: "灵葫仙缘")
        let picture = app.buttons["视频画面"]
        let videoPoint = picture.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let finished = app.staticTexts["本集已播完，上滑观看下一集"]
        let startedOrFinished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            picture.value as? String == "播放中" || finished.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [startedOrFinished], timeout: 60), .completed)
        if !finished.exists { videoPoint.doubleTap() }
        assertPlayback("已暂停", in: app, timeout: 5)

        let favorite = app.buttons["player.favorite"]
        let toggle = app.buttons["discussion.toggle"].firstMatch
        let openComments = app.buttons["discussion.comments"].firstMatch
        let commentBar = app.navigationBars["第 1 集评论"]
        func closeComments() {
            let done = app.navigationBars.buttons["完成"].firstMatch
            XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 5))
            done.tap()
            XCTAssertTrue(done.wait(for: \.exists, toEqual: false, timeout: 5))
        }
        let title = app.buttons["player.dramaTitle"]
        let episodeNumber = app.staticTexts["第 1 集"]
        XCTAssertTrue(title.wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertTrue(episodeNumber.waitForExistence(timeout: 5))
        XCTAssertLessThan(episodeNumber.frame.midX, app.frame.midX)
        XCTAssertLessThan(episodeNumber.frame.midY, app.frame.midY)
        XCTAssertLessThan(title.frame.minX, app.frame.minX + 0.25 * app.frame.width)
        XCTAssertGreaterThan(title.frame.midY, app.frame.midY)
        let controls = [favorite, toggle, openComments]
        for control in controls {
            XCTAssertTrue(control.wait(for: \.isHittable, toEqual: true, timeout: 10))
            XCTAssertGreaterThan(control.frame.midX, app.frame.minX + 0.75 * app.frame.width)
            XCTAssertEqual(control.frame.midX, favorite.frame.midX, accuracy: 3)
        }
        XCTAssertLessThanOrEqual(favorite.frame.maxY, toggle.frame.minY)
        XCTAssertLessThanOrEqual(toggle.frame.maxY, openComments.frame.minY)
        XCTAssertEqual(toggle.label, "评论弹幕")
        XCTAssertEqual(toggle.frame.width, 44, accuracy: 2)
        XCTAssertEqual(toggle.frame.height, 44, accuracy: 2)
        XCTAssertFalse(app.buttons["小窗播放"].exists)
        XCTAssertFalse(app.buttons["player.pip"].exists)
        for label in ["上一集", "暂停", "播放", "下一集"] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists, label)
        }
        XCTAssertTrue(title.label.hasSuffix("，第 1 集"))

        if toggle.value as? String != "开启" { toggle.tap() }
        expectValue("开启", of: toggle)
        let loadedCount = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.commentCount(in: openComments.value as? String).map { $0 > 0 } == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loadedCount], timeout: 30), .completed,
                       "The real episode must show a positive accessibility comment count")
        let count = try XCTUnwrap(commentCount(in: openComments.value as? String))
        capture("portrait-player-right-rail")
        let progress = app.sliders["播放进度"]
        let timestamps = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9]+:[0-9]{2}"))
        func elapsedSeconds() -> Int? {
            guard progress.isHittable else { return nil }
            let elapsed = timestamps.allElementsBoundByIndex.first { $0.frame.maxX <= progress.frame.minX + 2 }
            let parts = elapsed?.label.split(separator: ":").compactMap { Int($0) } ?? []
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        XCTAssertTrue(progress.wait(for: \.isEnabled, toEqual: true, timeout: 10))
        progress.adjust(toNormalizedSliderPosition: 0)
        let atStart = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            elapsedSeconds() == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [atStart], timeout: 5), .completed)

        videoPoint.doubleTap()
        assertPlayback("播放中", in: app, timeout: 15)
        let playedFiveSeconds = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (elapsedSeconds() ?? 0) >= 5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [playedFiveSeconds], timeout: 30), .completed)
        assertPlayback("播放中", in: app, timeout: 5)
        XCTAssertEqual(toggle.value as? String, "开启")
        XCTAssertEqual(commentCount(in: openComments.value as? String), count)
        let firstFrame = XCUIScreen.main.screenshot()
        Thread.sleep(forTimeInterval: 0.7)
        let secondFrame = XCUIScreen.main.screenshot()
        videoPoint.doubleTap()
        assertPlayback("已暂停", in: app, timeout: 5)
        assertEpisode(1, in: app)
        attach(firstFrame, named: "danmaku-playing-frame-1")
        attach(secondFrame, named: "danmaku-playing-frame-2")
        openComments.tap()
        XCTAssertTrue(commentBar.waitForExistence(timeout: 8))
        let header = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@",
            "(共 [0-9]+ 条评论 · 官网公开预览 [0-9]+ 条|官方播放页公开评论 · [0-9]+ 条)")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let counts = header.label.split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
        if header.label.hasPrefix("共 ") {
            XCTAssertEqual(counts.count, 2)
            XCTAssertEqual(counts.first, count, "The sheet total must match the comment button")
            let previewCount = try XCTUnwrap(counts.last)
            XCTAssertGreaterThan(previewCount, 0)
            XCTAssertLessThan(previewCount, count)
        } else {
            XCTAssertEqual(counts.count, 1)
            let previewCount = try XCTUnwrap(counts.first)
            XCTAssertGreaterThanOrEqual(previewCount, count, "Only a larger total uses the two-count header")
        }
        let rows = app.collectionViews.cells.allElementsBoundByIndex
        let visibleBodies = rows.compactMap { row -> XCUIElement? in
            let body = row.staticTexts.allElementsBoundByIndex.last
            guard let body, body.isHittable, body.frame.minY >= header.frame.maxY,
                  !body.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return body
        }
        XCTAssertFalse(visibleBodies.isEmpty, "Expected a visible live comment body")
        capture("episode-comments")
        let sheetSwitch = app.switches["轮播本集评论弹幕"].switches.firstMatch
        XCTAssertTrue(sheetSwitch.wait(for: \.isHittable, toEqual: true, timeout: 5))
        expectValue("1", of: sheetSwitch)
        sheetSwitch.tap()
        expectValue("0", of: sheetSwitch)
        XCTAssertTrue(commentBar.exists)
        closeComments()
        assertEpisode(1, in: app)
        assertPlayback("已暂停", in: app, timeout: 5)
        expectValue("关闭", of: toggle)
        app.terminate(); app.launch()
        XCTAssertTrue(toggle.wait(for: \.isHittable, toEqual: true, timeout: 45))
        expectValue("关闭", of: toggle)

        XCTContext.runActivity(named: "Landscape home discussion controls") { _ in
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
            XCTAssertTrue(toggle.wait(for: \.isHittable, toEqual: true, timeout: 10))
            toggle.tap()
            expectValue("开启", of: toggle)
            capture("landscape-home-discussion-controls")
            XCTAssertTrue(openComments.wait(for: \.isHittable, toEqual: true, timeout: 10))
            openComments.tap()
            XCTAssertTrue(commentBar.waitForExistence(timeout: 8))
            capture("landscape-home-comments")
            closeComments()
            XCTAssertTrue(toggle.wait(for: \.isHittable, toEqual: true, timeout: 10))
            toggle.tap()
            expectValue("关闭", of: toggle)
        }
    }

    func testGestureHintAppearsOncePerOpenAndStopsAfterThree() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_MODE"] == "--live")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HONGGUO_QA_FRESH_HINT_COUNTER"] == "1",
                          "Reset playback.gestureHintDisplays on the QA simulator before this test.")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios")
        app.launchArguments = ["-theme", "immersive", "-hasChosenTheme", "YES", "-updates.checkOnLaunch", "NO", "-autoNext", "NO"]
        app.launch()
        openFirstEpisode(in: app, search: "无限白粥")
        let hint = app.descendants(matching: .any)["player.gestureHint"].firstMatch
        let close = app.buttons["关闭播放器"]

        for opening in 1...4 {
            if opening > 1 { openFirstEpisodeFromDetail(in: app) }
            if opening <= 3 {
                XCTAssertTrue(hint.waitForExistence(timeout: 60), "Expected one hint on open \(opening)")
                capture("gesture-hint-open-\(opening)")
                XCTAssertTrue(hint.wait(for: \.exists, toEqual: false, timeout: 8))
            }
            if opening == 1 {
                let video = app.buttons["视频画面"]
                let point = video.coordinate(withNormalizedOffset: CGVector(dx: 0.27, dy: 0.44))
                let picker = app.buttons["player.episodes"]
                point.tap()
                XCTAssertTrue(picker.wait(for: \.isHittable, toEqual: false, timeout: 5))
                point.tap()
                XCTAssertTrue(picker.wait(for: \.isHittable, toEqual: true, timeout: 5))
                picker.tap()
                let second = app.buttons["2"]
                XCTAssertTrue(second.waitForExistence(timeout: 5))
                second.tap()
                assertEpisode(2, in: app)
                assertPlayback("播放中", in: app)
                assertNoGestureHint(hint, reason: "Revealing controls and changing episodes must not count as opening the player")
            }
            if opening == 4 {
                assertPlayback("播放中", in: app)
                assertNoGestureHint(hint, reason: "The fourth opening must not show a hint")
            }
            close.tap()
            XCTAssertTrue(app.navigationBars["剧集详情"].waitForExistence(timeout: 8))
        }
    }

    private func openFirstEpisode(in app: XCUIApplication, search: String) {
        let discover = app.tabBars.buttons["剧场"]
        XCTAssertTrue(discover.waitForExistence(timeout: 25)); discover.tap()
        let searchButton = app.buttons["搜索短剧"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15)); searchButton.tap()
        let input = app.textFields["搜索剧名或关键词"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText(search)
        app.buttons["搜索"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", search, "查看选集")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 40), "Missing live catalogue sample \(search)")
        result.tap()
        openFirstEpisodeFromDetail(in: app)
    }

    private func openFirstEpisodeFromDetail(in app: XCUIApplication) {
        waitForDetailPlaybackOptions(in: app)
        let firstEpisode = app.buttons.matching(NSPredicate(format: "label == %@", "播放第 1 集"))
        for _ in 0..<8 {
            if let play = firstEpisode.allElementsBoundByIndex.first(where: \.isHittable) {
                play.tap()
                assertEpisode(1, in: app)
                return
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTFail("Could not find episode 1 in the detail page's episode list")
    }

    private func waitForDetailPlaybackOptions(in app: XCUIApplication) {
        let playButtons = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "播放第 [0-9]+ 集"))
        XCTAssertTrue(playButtons.firstMatch.waitForExistence(timeout: 30))
    }

    private func returnFromThemeSettings(in app: XCUIApplication) {
        for title in ["主题样式", "设置"] {
            let back = app.navigationBars[title].buttons.firstMatch
            XCTAssertTrue(back.wait(for: \.isHittable, toEqual: true, timeout: 5))
            back.tap()
        }
    }

    private func openPlayerMore(in app: XCUIApplication, line: UInt = #line) -> XCUIElement {
        let more = app.buttons["player.more"]
        XCTAssertTrue(more.wait(for: \.isHittable, toEqual: true, timeout: 5), line: line)
        more.tap()
        let done = app.navigationBars["更多"].buttons["完成"]
        XCTAssertTrue(done.wait(for: \.isHittable, toEqual: true, timeout: 5), line: line)
        return done
    }

    private func revealMoreOption(_ option: XCUIElement, in app: XCUIApplication, line: UInt = #line) {
        if !option.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(option.wait(for: \.isHittable, toEqual: true, timeout: 5), line: line)
    }

    private func assertPlayerChoice(_ label: String, in app: XCUIApplication, line: UInt = #line) {
        let option = app.buttons[label]
        XCTAssertTrue(option.wait(for: \.isSelected, toEqual: true, timeout: 5), "Expected selected option \(label)", line: line)
    }

    private func closePlayerMore(_ done: XCUIElement, line: UInt = #line) {
        XCTAssertTrue(done.isHittable, line: line)
        done.tap()
        XCTAssertTrue(done.wait(for: \.exists, toEqual: false, timeout: 5), line: line)
    }

    private func assertEpisode(_ episode: Int, in app: XCUIApplication, line: UInt = #line) {
        let title = app.buttons["player.dramaTitle"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "，第 \(episode) 集"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 15), .completed, "Expected episode \(episode)", line: line)
    }

    private func assertPlayback(_ state: String, in app: XCUIApplication, timeout: TimeInterval = 60, line: UInt = #line) {
        let video = app.buttons["视频画面"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: video)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, "Expected video accessibility value \(state)", line: line)
    }

    private func assertNoGestureHint(_ hint: XCUIElement, reason: String, line: UInt = #line) {
        let unexpectedlyVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in hint.exists }, object: nil)
        unexpectedlyVisible.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unexpectedlyVisible], timeout: 5), .completed, reason, line: line)
    }

    private func commentCount(in value: String?) -> Int? {
        guard let value, value.hasSuffix(" 条") else { return nil }
        return Int(value.dropLast(2))
    }

    private func capture(_ name: String) {
        attach(XCUIScreen.main.screenshot(), named: name)
        let tree = XCTAttachment(string: XCUIApplication(bundleIdentifier: "com.ooiua.hongguo.ios").debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
