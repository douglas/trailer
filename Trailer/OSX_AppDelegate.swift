
var app: OSX_AppDelegate!

final class OSX_AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSUserNotificationCenterDelegate, NSOpenSavePanelDelegate {

	// Globals
	weak var refreshTimer: Timer?
	var openingWindow = false
	var isManuallyScrolling = false
	var ignoreNextFocusLoss = false
	var scrollBarWidth: CGFloat = 0.0

	private var systemSleeping = false
	private var globalKeyMonitor: AnyObject?
	private var localKeyMonitor: AnyObject?
	private var mouseIgnoreTimer: PopTimer!

	func setupWindows() {

		darkMode = currentSystemDarkMode()

		for d in menuBarSets {
			d.throwAway()
		}
		menuBarSets.removeAll()

		var newSets = [MenuBarSet]()
		for groupLabel in Repo.allGroupLabels {
			let c = GroupingCriterion(repoGroup: groupLabel)
			let s = MenuBarSet(viewCriterion: c, delegate: self)
			s.setTimers()
			newSets.append(s)
		}

		if Settings.showSeparateApiServersInMenu {
			for a in ApiServer.allApiServersInMoc(mainObjectContext) {
				if a.goodToGo {
					let c = GroupingCriterion(apiServerId: a.objectID)
					let s = MenuBarSet(viewCriterion: c, delegate: self)
					s.setTimers()
					newSets.append(s)
				}
			}
		}

		if newSets.count == 0 || Repo.anyVisibleReposInMoc(mainObjectContext, excludeGrouped: true) {
			let s = MenuBarSet(viewCriterion: nil, delegate: self)
			s.setTimers()
			newSets.append(s)
		}

		menuBarSets.append(contentsOf: newSets.reversed())

		updateScrollBarWidth() // also updates menu

		for d in menuBarSets {
			d.prMenu.scrollToTop()
			d.issuesMenu.scrollToTop()

			d.prMenu.updateVibrancy()
			d.issuesMenu.updateVibrancy()
		}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		app = self

		DistributedNotificationCenter.default().addObserver(self, selector: #selector(OSX_AppDelegate.updateDarkMode), name: "AppleInterfaceThemeChangedNotification" as NSNotification.Name, object: nil)

		DataManager.postProcessAllItems()

		mouseIgnoreTimer = PopTimer(timeInterval: 0.4) {
			app.isManuallyScrolling = false
		}

		updateDarkMode() // also sets up windows

		api.updateLimitsFromServer()

		let nc = NSUserNotificationCenter.default
		nc.delegate = self
		if let launchNotification = (notification as NSNotification).userInfo?[NSApplicationLaunchUserNotificationKey] as? NSUserNotification {
			delay(0.5) { [weak self] in
				self?.userNotificationCenter(nc, didActivate: launchNotification)
			}
		}

		if ApiServer.someServersHaveAuthTokensInMoc(mainObjectContext) {
			atNextEvent(self) { S in
				S.startRefresh()
			}
		} else if ApiServer.countApiServersInMoc(mainObjectContext) == 1, let a = ApiServer.allApiServersInMoc(mainObjectContext).first, a.authToken == nil || a.authToken!.isEmpty {
			startupAssistant()
		} else {
			preferencesSelected()
		}

		let n = NotificationCenter.default
		n.addObserver(self, selector: #selector(OSX_AppDelegate.updateScrollBarWidth), name: NSNotification.Name.NSPreferredScrollerStyleDidChange, object: nil)

		addHotKeySupport()

		let s = SUUpdater.shared()
		setUpdateCheckParameters()
		if !(s?.updateInProgress)! && Settings.checkForUpdatesAutomatically {
			s?.checkForUpdatesInBackground()
		}

		let wn = NSWorkspace.shared().notificationCenter
		wn.addObserver(self, selector: #selector(OSX_AppDelegate.systemWillSleep), name: NSNotification.Name.NSWorkspaceWillSleep, object: nil)
		wn.addObserver(self, selector: #selector(OSX_AppDelegate.systemDidWake), name: NSNotification.Name.NSWorkspaceDidWake, object: nil)

		// Unstick OS X notifications with custom actions but without an identifier, causes OS X to keep them forever
		if #available(OSX 10.10, *) {
			for notification in nc.deliveredNotifications {
				if notification.additionalActions != nil && notification.identifier == nil {
					nc.removeAllDeliveredNotifications()
					break
				}
			}
		}
	}

	func systemWillSleep() {
		systemSleeping = true
		DLog("System is going to sleep")
	}

	func systemDidWake() {
		DLog("System woke up")
		systemSleeping = false
		delay(1, self) { S in
			S.updateDarkMode()
			S.startRefreshIfItIsDue()
		}
	}

	func setUpdateCheckParameters() {
		if let s = SUUpdater.shared() {
			let autoCheck = Settings.checkForUpdatesAutomatically
			s.automaticallyChecksForUpdates = autoCheck
			if autoCheck {
				s.updateCheckInterval = TimeInterval(3600)*TimeInterval(Settings.checkForUpdatesInterval)
			}
			DLog("Check for updates set to %@, every %f seconds", s.automaticallyChecksForUpdates ? "true" : "false", s.updateCheckInterval)
		}
	}

	func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
		return false
	}

	func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {

		if let userInfo = notification.userInfo {

			func saveAndRefresh(_ i: ListableItem) {
				DataManager.saveDB()
				updateRelatedMenusFor(i)
			}

			switch notification.activationType {
			case .additionalActionClicked:
				if #available(OSX 10.10, *) {
					if notification.additionalActivationAction?.identifier == "mute" {
						if let (_,i) = ListableItem.relatedItemsFromNotificationInfo(userInfo) {
							i.setMute(true)
							saveAndRefresh(i)
						}
						break
					} else if notification.additionalActivationAction?.identifier == "read" {
						if let (_,i) = ListableItem.relatedItemsFromNotificationInfo(userInfo) {
							i.catchUpWithComments()
							saveAndRefresh(i)
						}
						break
					}
				}
			case .actionButtonClicked, .contentsClicked:
				var urlToOpen = userInfo[NOTIFICATION_URL_KEY] as? String
				if urlToOpen == nil {
					if let (c,i) = ListableItem.relatedItemsFromNotificationInfo(userInfo) {
						urlToOpen = c?.webUrl ?? i.webUrl
						i.catchUpWithComments()
						saveAndRefresh(i)
					}
				}
				if let up = urlToOpen, let u = URL(string: up) {
					NSWorkspace.shared().open(u)
				}
			default: break
			}
		}
		NSUserNotificationCenter.default.removeDeliveredNotification(notification)
	}

	func postNotificationOfType(_ type: NotificationType, forItem: DataItem) {
		if preferencesDirty {
			return
		}

		let notification = NSUserNotification()
		notification.userInfo = DataManager.infoForType(type, item: forItem)

		func addPotentialExtraActions() {
			if #available(OSX 10.10, *) {
				notification.additionalActions = [
					NSUserNotificationAction(identifier: "mute", title: "Mute this item"),
					NSUserNotificationAction(identifier: "read", title: "Mark this item as read")
				]
			}
		}

		switch type {
		case .newMention:
			let c = forItem as! PRComment
			if c.parentShouldSkipNotifications { return }
			notification.title = "@\(S(c.userName)) mentioned you:"
			notification.subtitle = c.notificationSubtitle
			notification.informativeText = c.body
			addPotentialExtraActions()
		case .newComment:
			let c = forItem as! PRComment
			if c.parentShouldSkipNotifications { return }
			notification.title = "@\(S(c.userName)) commented:"
			notification.subtitle = c.notificationSubtitle
			notification.informativeText = c.body
			addPotentialExtraActions()
		case .newPr:
			let p = forItem as! PullRequest
			if p.shouldSkipNotifications { return }
			notification.title = "New PR"
			notification.subtitle = p.repo.fullName
			notification.informativeText = p.title
			addPotentialExtraActions()
		case .prReopened:
			let p = forItem as! PullRequest
			if p.shouldSkipNotifications { return }
			notification.title = "Re-Opened PR"
			notification.subtitle = p.repo.fullName
			notification.informativeText = p.title
			addPotentialExtraActions()
		case .prMerged:
			let p = forItem as! PullRequest
			if p.shouldSkipNotifications { return }
			notification.title = "PR Merged!"
			notification.subtitle = p.repo.fullName
			notification.informativeText = p.title
			addPotentialExtraActions()
		case .prClosed:
			let p = forItem as! PullRequest
			if p.shouldSkipNotifications { return }
			notification.title = "PR Closed"
			notification.subtitle = p.repo.fullName
			notification.informativeText = p.title
			addPotentialExtraActions()
		case .newRepoSubscribed:
			notification.title = "New Repository Subscribed"
			notification.subtitle = (forItem as! Repo).fullName
		case .newRepoAnnouncement:
			notification.title = "New Repository"
			notification.subtitle = (forItem as! Repo).fullName
		case .newPrAssigned:
			let p = forItem as! PullRequest
			if p.shouldSkipNotifications { return } // unmute on assignment option?
			notification.title = "PR Assigned"
			notification.subtitle = p.repo.fullName
			notification.informativeText = p.title
			addPotentialExtraActions()
		case .newStatus:
			let s = forItem as! PRStatus
			if s.parentShouldSkipNotifications { return }
			notification.title = "PR Status Update"
			notification.subtitle = s.descriptionText
			notification.informativeText = s.pullRequest.title
			addPotentialExtraActions()
		case .newIssue:
			let i = forItem as! Issue
			if i.shouldSkipNotifications { return }
			notification.title = "New Issue"
			notification.subtitle = i.repo.fullName
			notification.informativeText = i.title
			addPotentialExtraActions()
		case .issueReopened:
			let i = forItem as! Issue
			if i.shouldSkipNotifications { return }
			notification.title = "Re-Opened Issue"
			notification.subtitle = i.repo.fullName
			notification.informativeText = i.title
			addPotentialExtraActions()
		case .issueClosed:
			let i = forItem as! Issue
			if i.shouldSkipNotifications { return }
			notification.title = "Issue Closed"
			notification.subtitle = i.repo.fullName
			notification.informativeText = i.title
			addPotentialExtraActions()
		case .newIssueAssigned:
			let i = forItem as! Issue
			if i.shouldSkipNotifications { return }
			notification.title = "Issue Assigned"
			notification.subtitle = i.repo.fullName
			notification.informativeText = i.title
			addPotentialExtraActions()
		}

		let t = S(notification.title)
		let s = S(notification.subtitle)
		let i = S(notification.informativeText)
		notification.identifier = "\(t) - \(s) - \(i)"

		let d = NSUserNotificationCenter.default
		if let c = forItem as? PRComment, let url = c.avatarUrl, !Settings.hideAvatars {
			_ = api.haveCachedAvatar(url) { image, _ in
				notification.contentImage = image
				d.deliver(notification)
			}
		} else {
			d.deliver(notification)
		}
	}

	func dataItemSelected(_ item: ListableItem, alternativeSelect: Bool, window: NSWindow?) {

		guard let w = window as? MenuWindow, let menuBarSet = menuBarSetForWindow(w) else { return }

		ignoreNextFocusLoss = alternativeSelect

		let urlToOpen = item.urlForOpening()
		item.catchUpWithComments()
		updateRelatedMenusFor(item)

		let window = item is PullRequest ? menuBarSet.prMenu : menuBarSet.issuesMenu
		let reSelectIndex = alternativeSelect ? window.table.selectedRow : -1
		window.filter.becomeFirstResponder()

		if reSelectIndex > -1 && reSelectIndex < window.table.numberOfRows {
			window.table.selectRowIndexes(IndexSet(integer: reSelectIndex), byExtendingSelection: false)
		}

		if let u = urlToOpen {
			NSWorkspace.shared().open(URL(string: u)!)
		}
	}

	func showMenu(_ menu: MenuWindow) {
		if !menu.isVisible {

			if let w = visibleWindow() {
				w.closeMenu()
			}

			menu.sizeAndShow(true)
		}
	}

	func sectionHeaderRemoveSelected(_ headerTitle: String) {

		guard let inMenu = visibleWindow(), let menuBarSet = menuBarSetForWindow(inMenu) else { return }

		if inMenu === menuBarSet.prMenu {
			if headerTitle == Section.merged.prMenuName() {
				if Settings.dontAskBeforeWipingMerged {
					removeAllMergedRequests(menuBarSet)
				} else {
					let mergedRequests = PullRequest.allMergedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion)

					let alert = NSAlert()
					alert.messageText = "Clear \(mergedRequests.count) merged PRs?"
					alert.informativeText = "This will clear \(mergedRequests.count) merged PRs from this list.  This action cannot be undone, are you sure?"
					alert.addButton(withTitle: "No")
					alert.addButton(withTitle: "Yes")
					alert.showsSuppressionButton = true

					if alert.runModal() == NSAlertSecondButtonReturn {
						removeAllMergedRequests(menuBarSet)
						if alert.suppressionButton!.state == NSOnState {
							Settings.dontAskBeforeWipingMerged = true
						}
					}
				}
			} else if headerTitle == Section.closed.prMenuName() {
				if Settings.dontAskBeforeWipingClosed {
					removeAllClosedRequests(menuBarSet)
				} else {
					let closedRequests = PullRequest.allClosedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion)

					let alert = NSAlert()
					alert.messageText = "Clear \(closedRequests.count) closed PRs?"
					alert.informativeText = "This will remove \(closedRequests.count) closed PRs from this list.  This action cannot be undone, are you sure?"
					alert.addButton(withTitle: "No")
					alert.addButton(withTitle: "Yes")
					alert.showsSuppressionButton = true

					if alert.runModal() == NSAlertSecondButtonReturn {
						removeAllClosedRequests(menuBarSet)
						if alert.suppressionButton!.state == NSOnState {
							Settings.dontAskBeforeWipingClosed = true
						}
					}
				}
			}
			if !menuBarSet.prMenu.isVisible {
				showMenu(menuBarSet.prMenu)
			}
		} else if inMenu === menuBarSet.issuesMenu {
			if headerTitle == Section.closed.issuesMenuName() {
				if Settings.dontAskBeforeWipingClosed {
					removeAllClosedIssues(menuBarSet)
				} else {
					let closedIssues = Issue.allClosedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion)

					let alert = NSAlert()
					alert.messageText = "Clear \(closedIssues.count) closed issues?"
					alert.informativeText = "This will remove \(closedIssues.count) closed issues from this list.  This action cannot be undone, are you sure?"
					alert.addButton(withTitle: "No")
					alert.addButton(withTitle: "Yes")
					alert.showsSuppressionButton = true

					if alert.runModal() == NSAlertSecondButtonReturn {
						removeAllClosedIssues(menuBarSet)
						if alert.suppressionButton!.state == NSOnState {
							Settings.dontAskBeforeWipingClosed = true
						}
					}
				}
			}
			if !menuBarSet.issuesMenu.isVisible {
				showMenu(menuBarSet.issuesMenu)
			}
		}
	}

	private func removeAllMergedRequests(_ menuBarSet: MenuBarSet) {
		for r in PullRequest.allMergedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion) {
			mainObjectContext.delete(r)
		}
		DataManager.saveDB()
		menuBarSet.updatePrMenu()
	}

	private func removeAllClosedRequests(_ menuBarSet: MenuBarSet) {
		for r in PullRequest.allClosedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion) {
			mainObjectContext.delete(r)
		}
		DataManager.saveDB()
		menuBarSet.updatePrMenu()
	}

	private func removeAllClosedIssues(_ menuBarSet: MenuBarSet) {
		for i in Issue.allClosedInMoc(mainObjectContext, criterion: menuBarSet.viewCriterion) {
			mainObjectContext.delete(i)
		}
		DataManager.saveDB()
		menuBarSet.updateIssuesMenu()
	}

	func unPinSelectedFor(_ item: ListableItem) {
		let relatedMenus = relatedMenusFor(item)
		mainObjectContext.delete(item)
		DataManager.saveDB()
		if item is PullRequest {
			relatedMenus.forEach { $0.updatePrMenu() }
		} else if item is Issue {
			relatedMenus.forEach { $0.updateIssuesMenu() }
		}
	}

	override func controlTextDidChange(_ n: Notification) {
		if let obj = n.object as? NSSearchField {

			guard let w = obj.window as? MenuWindow, let menuBarSet = menuBarSetForWindow(w) else { return }

			if obj === menuBarSet.prMenu.filter {
				menuBarSet.prFilterTimer.push()
			} else if obj === menuBarSet.issuesMenu.filter {
				menuBarSet.issuesFilterTimer.push()
			}
		}
	}

	func markAllReadSelectedFrom(_ window: MenuWindow) {

		guard let menuBarSet = menuBarSetForWindow(window) else { return }

		let type = window === menuBarSet.prMenu ? "PullRequest" : "Issue"
		let f = ListableItem.requestForItemsOfType(type, withFilter: window.filter.stringValue, sectionIndex: -1, criterion: menuBarSet.viewCriterion)
		for r in try! mainObjectContext.fetch(f) {
			r.catchUpWithComments()
		}
		updateAllMenus()
	}

	func preferencesSelected() {
		refreshTimer?.invalidate()
		refreshTimer = nil
		showPreferencesWindow(nil)
	}

	func application(_ sender: NSApplication, openFile filename: String) -> Bool {
		let url = URL(fileURLWithPath: filename)
		let ext = ((filename as NSString).lastPathComponent as NSString).pathExtension
		if ext == "trailerSettings" {
			DLog("Will open %@", url.absoluteString)
			_ = tryLoadSettings(url, skipConfirm: Settings.dontConfirmSettingsImport)
			return true
		}
		return false
	}

	func tryLoadSettings(_ url: URL, skipConfirm: Bool) -> Bool {
		if appIsRefreshing {
			let alert = NSAlert()
			alert.messageText = "Trailer is currently refreshing data, please wait until it's done and try importing your settings again"
			alert.addButton(withTitle: "OK")
			alert.runModal()
			return false

		} else if !skipConfirm {
			let alert = NSAlert()
			alert.messageText = "Import settings from this file?"
			alert.informativeText = "This will overwrite all your current Trailer settings, are you sure?"
			alert.addButton(withTitle: "No")
			alert.addButton(withTitle: "Yes")
			alert.showsSuppressionButton = true
			if alert.runModal() == NSAlertSecondButtonReturn {
				if alert.suppressionButton!.state == NSOnState {
					Settings.dontConfirmSettingsImport = true
				}
			} else {
				return false
			}
		}

		if !Settings.readFromURL(url) {
			let alert = NSAlert()
			alert.messageText = "The selected settings file could not be imported due to an error"
			alert.addButton(withTitle: "OK")
			alert.runModal()
			return false
		}
		DataManager.postProcessAllItems()
		DataManager.saveDB()
		preferencesWindow?.reloadSettings()
		setupWindows()
		preferencesDirty = true
		startRefresh()

		return true
	}

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplicationTerminateReply {
		DataManager.saveDB()
		return .terminateNow
	}

	func windowDidBecomeKey(_ notification: Notification) {
		if let window = notification.object as? MenuWindow {
			if ignoreNextFocusLoss {
				ignoreNextFocusLoss = false
			} else {
				window.scrollToTop()
				window.table.deselectAll(nil)
			}
			window.filter.becomeFirstResponder()
		}
	}

	func windowDidResignKey(_ notification: Notification) {
		if ignoreNextFocusLoss {
			NSApp.activateIgnoringOtherApps(true)
		} else if !openingWindow {
			if let w = notification.object as? MenuWindow {
				w.closeMenu()
			}
		}
	}
	
	func startRefreshIfItIsDue() {

		if let l = Settings.lastSuccessfulRefresh {
			let howLongAgo = Date().timeIntervalSince(l)
			if fabs(howLongAgo) > TimeInterval(Settings.refreshPeriod) {
				startRefresh()
			} else {
				let howLongUntilNextSync = TimeInterval(Settings.refreshPeriod) - howLongAgo
				DLog("No need to refresh yet, will refresh in %f", howLongUntilNextSync)
				refreshTimer = Timer.scheduledTimer(timeInterval: howLongUntilNextSync, target: self, selector: #selector(OSX_AppDelegate.refreshTimerDone), userInfo: nil, repeats: false)
			}
		}
		else
		{
			startRefresh()
		}
	}

	private func checkApiUsage() {
		for apiServer in ApiServer.allApiServersInMoc(mainObjectContext) {
			if apiServer.goodToGo && apiServer.hasApiLimit, let resetDate = apiServer.resetDate {
				if apiServer.shouldReportOverTheApiLimit {
					let apiLabel = S(apiServer.label)
					let resetDateString = itemDateFormatter.string(from: resetDate)

					let alert = NSAlert()
					alert.messageText = "Your API request usage for '\(apiLabel)' is over the limit!"
					alert.informativeText = "Your request cannot be completed until your hourly API allowance is reset \(resetDateString).\n\nIf you get this error often, try to make fewer manual refreshes or reducing the number of repos you are monitoring.\n\nYou can check your API usage at any time from 'Servers' preferences pane at any time."
					alert.addButton(withTitle: "OK")
					alert.runModal()
				} else if apiServer.shouldReportCloseToApiLimit {
					let apiLabel = S(apiServer.label)
					let resetDateString = itemDateFormatter.string(from: resetDate)

					let alert = NSAlert()
					alert.messageText = "Your API request usage for '\(apiLabel)' is close to full"
					alert.informativeText = "Try to make fewer manual refreshes, increasing the automatic refresh time, or reducing the number of repos you are monitoring.\n\nYour allowance will be reset by GitHub \(resetDateString).\n\nYou can check your API usage from the 'Servers' preferences pane at any time."
					alert.addButton(withTitle: "OK")
					alert.runModal()
				}
			}
		}
	}

	func prepareForRefresh() {
		refreshTimer?.invalidate()
		refreshTimer = nil

		api.expireOldImageCacheEntries()
		DataManager.postMigrationTasks()

		appIsRefreshing = true
		preferencesWindow?.updateActivity()

		for d in menuBarSets {
			d.prepareForRefresh()
		}

		DLog("Starting refresh")
	}

	func completeRefresh() {
		appIsRefreshing = false
		preferencesDirty = false
		preferencesWindow?.updateActivity()
		DataManager.saveDB()
		preferencesWindow?.projectsTable.reloadData()
		checkApiUsage()
		DataManager.sendNotificationsIndexAndSave()
		DLog("Refresh done")
		updateAllMenus()
	}

	func updateRelatedMenusFor(_ i: ListableItem) {
		let relatedMenus = relatedMenusFor(i)
		if i is PullRequest {
			relatedMenus.forEach { $0.updatePrMenu() }
		} else if i is Issue {
			relatedMenus.forEach { $0.updateIssuesMenu() }
		}
	}

	private func relatedMenusFor(_ i: ListableItem) -> [MenuBarSet] {
		return menuBarSets.flatMap{ ($0.viewCriterion?.isRelatedTo(i) ?? true) ? $0 : nil }
	}

	func updateAllMenus() {
		var visibleMenuCount = 0
		for d in menuBarSets {
			d.forceVisible = false
			d.updatePrMenu()
			d.updateIssuesMenu()
			if d.prMenu.statusItem != nil { visibleMenuCount += 1 }
			if d.issuesMenu.statusItem != nil { visibleMenuCount += 1 }
		}
		if visibleMenuCount == 0 && menuBarSets.count > 0 {
			// Safety net: Ensure that at the very least (usually while importing
			// from an empty DB, with all repos in groups) *some* menu stays visible
			let m = menuBarSets.first!
			m.forceVisible = true
			m.updatePrMenu()
		}
	}

	func startRefresh() {
		if appIsRefreshing {
			DLog("Won't start refresh because refresh is already ongoing")
			return
		}

		if systemSleeping {
			DLog("Won't start refresh because the system is in power-nap / sleep")
			return
		}

		if api.noNetworkConnection() {
			DLog("Won't start refresh because internet connectivity is down")
			return
		}

		if !ApiServer.someServersHaveAuthTokensInMoc(mainObjectContext) {
			DLog("Won't start refresh because there are no configured API servers")
			return
		}

		prepareForRefresh()

		for d in menuBarSets {
			d.allowRefresh = false
		}

		api.syncItemsForActiveReposAndCallback(nil) { [weak self] in

			guard let s = self else { return }

			for d in s.menuBarSets {
				d.allowRefresh = true
			}

			if !ApiServer.shouldReportRefreshFailureInMoc(mainObjectContext) {
				Settings.lastSuccessfulRefresh = Date()
			}
			s.completeRefresh()
			s.refreshTimer = Timer.scheduledTimer(timeInterval: TimeInterval(Settings.refreshPeriod), target: s, selector: #selector(OSX_AppDelegate.refreshTimerDone), userInfo: nil, repeats: false)
		}
	}

	func refreshTimerDone() {
		if DataManager.appIsConfigured {
			if preferencesWindow != nil {
				preferencesDirty = true
			} else {
				startRefresh()
			}
		}
	}

	/////////////////////// keyboard shortcuts

	func statusItemList() -> [NSStatusItem] {
		var list = [NSStatusItem]()
		for s in menuBarSets {
			if let i = s.prMenu.statusItem, let v = i.view, v.frame.size.width > 0 {
				list.append(i)
			}
			if let i = s.issuesMenu.statusItem, let v = i.view, v.frame.size.width > 0 {
				list.append(i)
			}
		}
		return list
	}

	func addHotKeySupport() {
		if Settings.hotkeyEnable {
			if globalKeyMonitor == nil {
				let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
				let options = [key: NSNumber(value: (AXIsProcessTrusted() == false))]
				if AXIsProcessTrustedWithOptions(options) == true {
					globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] incomingEvent in
						_ = self?.checkForHotkey(incomingEvent)
					}
				}
			}
		} else {
			if globalKeyMonitor != nil {
				NSEvent.removeMonitor(globalKeyMonitor!)
				globalKeyMonitor = nil
			}
		}

		if localKeyMonitor != nil {
			return
		}

		localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (incomingEvent) -> NSEvent? in

			guard let S = self else { return incomingEvent }

			if S.checkForHotkey(incomingEvent) ?? false {
				return nil
			}

			if let w = incomingEvent.window as? MenuWindow {
				//DLog("Keycode: %d", incomingEvent.keyCode)

				switch incomingEvent.keyCode {
				case 123, 124: // left, right
					if !(hasModifier(incomingEvent, .command) && hasModifier(incomingEvent, .option)) {
						return incomingEvent
					}

					if app.isManuallyScrolling && w.table.selectedRow == -1 { return nil }

					let statusItems = S.statusItemList()
					if let s = w.statusItem, let ind = statusItems.index(of: s) {
						var nextIndex = incomingEvent.keyCode==123 ? ind+1 : ind-1
						if nextIndex < 0 {
							nextIndex = statusItems.count-1
						} else if nextIndex >= statusItems.count {
							nextIndex = 0
						}
						let newStatusItem = statusItems[nextIndex]
						for s in S.menuBarSets {
							if s.prMenu.statusItem === newStatusItem {
								S.showMenu(s.prMenu)
								break
							} else if s.issuesMenu.statusItem === newStatusItem {
								S.showMenu(s.issuesMenu)
								break
							}
						}
					}
					return nil
				case 125: // down
					if hasModifier(incomingEvent, .shift) {
						return incomingEvent
					}
					if app.isManuallyScrolling && w.table.selectedRow == -1 { return nil }
					var i = w.table.selectedRow + 1
					if i < w.table.numberOfRows {
						while w.itemDelegate.itemAtRow(i) == nil { i += 1 }
						S.scrollToIndex(i, inMenu: w)
					}
					return nil
				case 126: // up
					if hasModifier(incomingEvent, .shift) {
						return incomingEvent
					}
					if app.isManuallyScrolling && w.table.selectedRow == -1 { return nil }
					var i = w.table.selectedRow - 1
					if i > 0 {
						while w.itemDelegate.itemAtRow(i) == nil { i -= 1 }
						S.scrollToIndex(i, inMenu: w)
					}
					return nil
				case 36: // enter
					if let c = NSTextInputContext.current(), c.client.hasMarkedText() {
						return incomingEvent
					}
					if app.isManuallyScrolling && w.table.selectedRow == -1 { return nil }
					if let dataItem = w.itemDelegate.itemAtRow(w.table.selectedRow) {
						let isAlternative = hasModifier(incomingEvent, .option)
						S.dataItemSelected(dataItem, alternativeSelect: isAlternative, window: w)
					}
					return nil
				case 53: // escape
					w.closeMenu()
					return nil
				default:
					break
				}
			}
			return incomingEvent
		}
	}

	private func scrollToIndex(_ i: Int, inMenu: MenuWindow) {
		app.isManuallyScrolling = true
		mouseIgnoreTimer.push()
		inMenu.table.scrollRowToVisible(i)
		atNextEvent {
			inMenu.table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
		}
	}

	func focusedItem() -> ListableItem? {
		if let w = visibleWindow() {
			return w.focusedItem()
		} else {
			return nil
		}
	}

	private func checkForHotkey(_ incomingEvent: NSEvent) -> Bool {
		var check = 0

		let cmdPressed = hasModifier(incomingEvent, .command)
		if Settings.hotkeyCommandModifier { check += cmdPressed ? 1 : -1 } else { check += cmdPressed ? -1 : 1 }

		let ctrlPressed = hasModifier(incomingEvent, .control)
		if Settings.hotkeyControlModifier { check += ctrlPressed ? 1 : -1 } else { check += ctrlPressed ? -1 : 1 }

		let altPressed = hasModifier(incomingEvent, .option)
		if Settings.hotkeyOptionModifier { check += altPressed ? 1 : -1 } else { check += altPressed ? -1 : 1 }

		let shiftPressed = hasModifier(incomingEvent, .shift)
		if Settings.hotkeyShiftModifier { check += shiftPressed ? 1 : -1 } else { check += shiftPressed ? -1 : 1 }

		let keyMap = [
			"A": 0, "B": 11, "C": 8, "D": 2, "E": 14, "F": 3, "G": 5, "H": 4, "I": 34, "J": 38,
			"K": 40, "L": 37, "M": 46, "N": 45, "O": 31, "P": 35, "Q": 12, "R": 15, "S": 1,
			"T": 17, "U": 32, "V": 9, "W": 13, "X": 7, "Y": 16, "Z": 6 ]

		if check==4, let n = keyMap[Settings.hotkeyLetter], incomingEvent.keyCode == UInt16(n) {
			if Repo.interestedInPrs() {
				showMenu(menuBarSets.first!.prMenu)
			} else if Repo.interestedInIssues() {
				showMenu(menuBarSets.first!.issuesMenu)
			}
			return true
		}

		return false
	}
	
	////////////// scrollbars
	
	func updateScrollBarWidth() {
		if let s = menuBarSets.first!.prMenu.scrollView.verticalScroller {
			if s.scrollerStyle == NSScrollerStyle.legacy {
				scrollBarWidth = s.frame.size.width
			} else {
				scrollBarWidth = 0
			}
		}
		updateAllMenus()
	}

	////////////////////// windows

	private var startupAssistantController: NSWindowController?
	private func startupAssistant() {
		if startupAssistantController == nil {
			startupAssistantController = NSWindowController(windowNibName:"SetupAssistant")
			if let w = startupAssistantController!.window as? SetupAssistant {
				w.level = Int(CGWindowLevelForKey(CGWindowLevelKey.floatingWindow))
				w.center()
				w.makeKeyAndOrderFront(self)
			}
		}
	}
	func closedSetupAssistant() {
		startupAssistantController = nil
	}

	private var aboutWindowController: NSWindowController?
	func showAboutWindow() {
		if aboutWindowController == nil {
			aboutWindowController = NSWindowController(windowNibName:"AboutWindow")
		}
		if let w = aboutWindowController!.window as? AboutWindow {
			w.level = Int(CGWindowLevelForKey(CGWindowLevelKey.floatingWindow))
			w.version.stringValue = versionString()
			w.center()
			w.makeKeyAndOrderFront(self)
		}
	}
	func closedAboutWindow() {
		aboutWindowController = nil
	}

	private var preferencesWindowController: NSWindowController?
	private var preferencesWindow: PreferencesWindow?
	func showPreferencesWindow(_ selectTab: Int?) {
		if preferencesWindowController == nil {
			preferencesWindowController = NSWindowController(windowNibName:"PreferencesWindow")
		}
		if let w = preferencesWindowController!.window as? PreferencesWindow {
			w.level = Int(CGWindowLevelForKey(CGWindowLevelKey.floatingWindow))
			w.center()
			w.makeKeyAndOrderFront(self)
			preferencesWindow = w
			if let s = selectTab {
				w.tabs.selectTabViewItem(at: s)
			}
		}
	}
	func closedPreferencesWindow() {
		preferencesWindow = nil
		preferencesWindowController = nil
	}

	func statusItemForView(_ view: NSView) -> NSStatusItem? {
		for d in menuBarSets {
			if d.prMenu.statusItem?.view === view { return d.prMenu.statusItem }
			if d.issuesMenu.statusItem?.view === view { return d.issuesMenu.statusItem }
		}
		return nil
	}

	func visibleWindow() -> MenuWindow? {
		for d in menuBarSets {
			if d.prMenu.isVisible { return d.prMenu }
			if d.issuesMenu.isVisible { return d.issuesMenu }
		}
		return nil
	}

	func updateVibrancies() {
		for d in menuBarSets {
			d.prMenu.updateVibrancy()
			d.issuesMenu.updateVibrancy()
		}
	}

	//////////////////////// Dark mode

	var darkMode = false
	func updateDarkMode() {
		if !systemSleeping {
			// kick the NSAppearance mechanism into action
			let s = NSStatusBar.system().statusItem(withLength: NSVariableStatusItemLength)
			s.statusBar.removeStatusItem(s)

			if menuBarSets.count == 0 || (darkMode != currentSystemDarkMode()) {
				setupWindows()
			}
		}
	}

	private func currentSystemDarkMode() -> Bool {
		if #available(OSX 10.10, *) {
			let c = NSAppearance.current()
			return c.name.contains(NSAppearanceNameVibrantDark)
		}
		return false
	}

	// Server display list
	private var menuBarSets = [MenuBarSet]()
	private func menuBarSetForWindow(_ window: MenuWindow) -> MenuBarSet? {
		for d in menuBarSets {
			if d.prMenu === window || d.issuesMenu === window {
				return d
			}
		}
		return nil
	}
}
