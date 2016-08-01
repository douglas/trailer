
extension NSTextField {
	final func trailerUndo() {
		self.currentEditor()?.undoManager?.undo()
	}
	final func trailerRedo() {
		self.currentEditor()?.undoManager?.redo()
	}
}

final class Application: NSApplication {
	override func sendEvent(_ event: NSEvent) {
		if event.type == .keyDown {
			let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			if modifiers == .command {
				if let char = event.charactersIgnoringModifiers {
					switch char {
					case "x": if sendAction(#selector(NSText.cut(_:)), to:nil, from:self) { return }
					case "v": if sendAction(#selector(NSText.paste(_:)), to:nil, from:self) { return }
					case "z": if sendAction(#selector(NSTextField.trailerUndo), to:nil, from:self) { return }
					case "c":
						if let url = app.focusedItem()?.webUrl {
							let p = NSPasteboard.general()
							p.clearContents()
							p.setString(url, forType:NSStringPboardType)
							return
						} else {
							if sendAction(#selector(NSText.copy(_:)), to:nil, from:self) { return }
						}
					case "s":
						if let i = app.focusedItem(), i.isSnoozing {
							i.wakeUp()
							DataManager.saveDB()
							app.updateRelatedMenusFor(i)
							return
						}
					case "m":
						if let i = app.focusedItem() {
							i.setMute(!(i.muted?.boolValue ?? false))
							DataManager.saveDB()
							app.updateRelatedMenusFor(i)
							return
						}
					case "a":
						if let i = app.focusedItem() {
							if i.unreadComments?.intValue > 0 {
								i.catchUpWithComments()
							} else {
								i.latestReadCommentDate = Date.distantPast
								i.postProcess()
							}
							DataManager.saveDB()
							app.updateRelatedMenusFor(i)
							return
						} else if sendAction(#selector(NSResponder.selectAll(_:)), to:nil, from:self) {
							return
						}
					case "o":
						if let i = app.focusedItem(), let w = i.repo.webUrl, let u = URL(string: w) {
							NSWorkspace.shared().open(u)
							return
						}
					default: break
					}
				}
			} else if modifiers == [.command, .shift] {
				if let char = event.charactersIgnoringModifiers {
					if char == "Z" && sendAction(#selector(NSTextField.trailerRedo), to:nil, from:self) { return }
				}
			}
		}
		super.sendEvent(event)
	}
}
