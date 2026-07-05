import AppKit

/// A scrollable "how the app works" manual, shown from the Info menu.
@MainActor
final class HelpWindowController {
    static let shared = HelpWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 660, height: 620))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 26, height: 22)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.textStorage?.setAttributedString(Self.manual())
        scroll.documentView = tv

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "LED OCD — Manual"
        w.contentView = scroll
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Content

    private static func manual() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let text = NSColor.labelColor
        let subtle = NSColor.secondaryLabelColor

        let titlePara = NSMutableParagraphStyle(); titlePara.paragraphSpacing = 10
        let headPara = NSMutableParagraphStyle(); headPara.paragraphSpacingBefore = 16; headPara.paragraphSpacing = 4
        let bodyPara = NSMutableParagraphStyle(); bodyPara.paragraphSpacing = 3; bodyPara.lineSpacing = 2
        let bulletPara = NSMutableParagraphStyle()
        bulletPara.paragraphSpacing = 3; bulletPara.lineSpacing = 2
        bulletPara.headIndent = 16; bulletPara.firstLineHeadIndent = 4

        func add(_ s: String, font: NSFont, color: NSColor, para: NSParagraphStyle) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        func title(_ s: String) { add(s, font: .boldSystemFont(ofSize: 19), color: text, para: titlePara) }
        func head(_ s: String) { add(s, font: .boldSystemFont(ofSize: 13.5), color: text, para: headPara) }
        func body(_ s: String) { add(s, font: .systemFont(ofSize: 12), color: text, para: bodyPara) }
        func bullet(_ s: String) { add("•  " + s, font: .systemFont(ofSize: 12), color: text, para: bulletPara) }

        title("LED OCD — Manual")
        body("This app lets you customize how the LED lamps on your pinball machine look, then save those settings onto your LED OCD or GI OCD board. Here's how everything works.")

        head("1. Connecting to your board")
        bullet("Plug the board into your Mac with its USB cable, click Scan, choose the board in the COM Select list, then click Connect. The app reads the board and shows what it is (LED or GI) and its firmware version at the top-right.")
        bullet("No board handy? Turn on \u{201C}Simulate Board\u{201D} in the Advanced menu to try everything out without any hardware. A red \u{201C}SIMULATED\u{201D} label reminds you it's pretend.")

        head("2. Choosing your machine")
        bullet("Pick your pinball machine from the Game Select list. This loads the name of every lamp on that machine (like \u{201C}Left Ramp\u{201D} or \u{201C}Jackpot\u{201D}), so you always know what you're editing.")
        bullet("The colored tags above the list filter it by manufacturer (WPC, Stern, Capcom), so you're not scrolling through hundreds of games. Click tags to turn them on and off — several can be on at once; with none on, every game is listed.")
        bullet("When you Connect (or Read), the detected manufacturer's tag lights up green automatically. Tags you enable yourself show amber.")
        bullet("If you pick a game that doesn't match your board, its tag turns red — a heads-up that the lamp layout won't line up.")

        head("3. Adding a machine that isn't listed")
        bullet("Click the \u{201C}new\u{201D} (＋) icon next to Game Select, give it a name, choose the layout, and type the lamp names into the Insert column. Click Save and it joins the list under \u{201C}Custom Games\u{201D}, with the built-in machines below under \u{201C}Default Games\u{201D}.")
        bullet("The clone icon copies the machine you're already on, so you can start from something close and just rename a few lamps.")
        bullet("With a custom game selected, a pencil icon renames it and a trashcan deletes it. Custom games are stored separately, so updating the machine list never touches them — and a custom game can even share a name with a default one without replacing it.")

        head("4. Setting the brightness (Profiles)")
        bullet("A \u{201C}profile\u{201D} is a brightness recipe. Each machine can use up to 8 of them. For each profile you set how dim (B1) to how bright (B8) it goes, plus a Delay that controls how smoothly it fades.")
        bullet("Normally you only set the dimmest and brightest values and the app fills in the steps between. Turn on Advanced if you'd rather hand-tune every step.")
        bullet("In the lamp list, the Select column is where you choose which profile each lamp uses. (Click a column header to sort the list.)")

        head("5. Tuning brightness live (Live Mode)")
        bullet("Live Mode lets you dial in a profile's brightness while watching the real lamps — no guessing at levels, and no saving over and over just to check.")
        bullet("Press the lamp button next to a profile and every lamp that uses it lights up. Now simply edit that profile's brightness values: the lamps change instantly as you type, so the number that looks right is exactly what gets saved. When it looks good, click Save — that's it.")
        bullet("Click any B1–B8 box to see that step on the lamps — the yellow box is the one currently showing. (With Advanced off you can edit B1 and B8; the steps between are click-to-view.) You can also light any single lamp to any brightness with the chooser in its row.")
        bullet("In short: Live Mode for tuning how things look. To check that lamps work or find which is which, use Manual Test (below).")

        head("6. Saving your setup to the board")
        bullet("Send loads your current settings onto the board so you can see them straight away.")
        bullet("Save stores them on the board for good, so they stay after the machine is powered off and on.")
        bullet("Read does the opposite — it fetches whatever settings are already on the board, in case you'd like to start from those.")
        bullet("Export backs your whole setup up to a file; Import loads one you saved before.")

        head("7. Checking your lamps (Manual Test)")
        bullet("Manual Test is about the hardware, not the look: it opens a window with every lamp as its own up/down control, so you can light any lamp to confirm it's wired correctly, or to work out which lamp is which on the playfield.")
        bullet("It also has a Checkerboard test pattern, a row to light every lamp on a profile at once, and a button to turn everything off. Closing the window returns the machine to normal play.")
        bullet("Rule of thumb: Live Mode for tuning how your profiles look; Manual Test for confirming lamps actually work.")

        head("8. GI OCD boards (general illumination)")
        bullet("If your board runs the general illumination (the flood lighting rather than the insert lamps), you'll see 6 light \u{201C}strings.\u{201D} For each one you set a resting brightness (Normal) and a brighter reaction (Active).")
        bullet("The Active brightness kicks in when something happens in the game (the string's Activity input) — for instance flashing up during a mode — then eases back down. Fade delay sets how quickly it eases; Activity duration is how long it stays bright.")
        bullet("50 Hz and Out freq fine-tune flicker so the lights look smooth in person and on camera.")

        head("Good to know")
        bullet("The panel at the bottom is a running log of what the app is doing.")
        bullet("Advanced ▸ Refresh Machine Data downloads the newest machine list from ledocd.com (your custom games are never touched).")
        bullet("Advanced ▸ Passthrough tells the board to step aside and let the game drive the lights like the original bulbs.")
        bullet("Advanced ▸ Show Matrix Override reveals a manual Matrix picker in the header — normally the matrix is set automatically by Connect or by the game you pick, but this lets you force one (e.g. Capcom A vs B).")

        add("\nBuilt entirely on the foundation of Harold Toler's LED & GI OCD.",
            font: .systemFont(ofSize: 11), color: subtle, para: bodyPara)
        return out
    }
}
