import AppKit
import ApplicationServices
import Foundation

let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func nodes(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 15 else { return [] }
    let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [root] + children.flatMap { nodes($0, depth: depth + 1) }
}

func text(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func lookup(_ label: String) -> AXUIElement? {
    nodes(app).first {
        text($0, kAXDescriptionAttribute) == label || text($0, kAXTitleAttribute) == label
    }
}

func press(_ label: String) throws {
    guard let element = lookup(label) else { throw NSError(domain: "UIProbe.missing.\(label)", code: 1) }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw NSError(domain: "UIProbe.press.\(label)", code: Int(result.rawValue)) }
}

func setLink(_ value: String) throws {
    guard let element = lookup("Media link") else { throw NSError(domain: "UIProbe.link", code: 1) }
    let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    guard result == .success else { throw NSError(domain: "UIProbe.set", code: Int(result.rawValue)) }
}

func wait(_ label: String, seconds: Double = 25, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { throw NSError(domain: "UIProbe.timeout.\(label)", code: 1) }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

func containsText(_ needle: String) -> Bool {
    nodes(app).contains { text($0, kAXValueAttribute).contains(needle) }
}

let mode = CommandLine.arguments[2]
if mode == "dump" {
    for node in nodes(app) {
        let role = text(node, kAXRoleAttribute)
        if ["AXButton", "AXRadioButton", "AXTextField", "AXStaticText", "AXPopUpButton"].contains(role) {
            print("\(role) | \(text(node, kAXDescriptionAttribute)) | \(text(node, kAXTitleAttribute)) | \(text(node, kAXValueAttribute)) | enabled=\(attribute(node, kAXEnabledAttribute) ?? "?" as CFString)")
        }
    }
} else if mode == "press" {
    try press(CommandLine.arguments[3])
} else if mode == "set" {
    try setLink(CommandLine.arguments[3])
} else if mode == "verify" {
    let base = CommandLine.arguments[3]
    try press("Add Link")
    try wait("link field") { lookup("Media link") != nil }
    try setLink("file:///etc/passwd")
    try press("Analyze")
    try wait("invalid URL error") { containsText("Enter a complete") }
    guard let download = lookup("Download"), (attribute(download, kAXEnabledAttribute) as? Bool) == false else {
        fatalError("Invalid URL enabled Download")
    }
    print("UI PASS: invalid URL rejected; Download disabled")
    try setLink(base + "/sample.mp4")
    try press("Analyze")
    try wait("media preview") { lookup("Download").map { attribute($0, kAXEnabledAttribute) as? Bool == true } ?? false }
    print("UI PASS: media analysis and preview")
    try press("Audio · MP3")
    try press("Download")
    try wait("audio completion") { containsText("Completed") && containsText("MP3") }
    print("UI PASS: MP3 completes through native controls")
    try press("Add Link")
    try wait("second link field") { lookup("Media link") != nil }
    try setLink(base + "/slow.mp4")
    try press("Analyze")
    try wait("second media preview") { lookup("Download").map { attribute($0, kAXEnabledAttribute) as? Bool == true } ?? false }
    try press("Download")
    try wait("video progress") { containsText("Downloading") && containsText("left") }
    try press("Pause Download")
    try wait("paused") { containsText("Paused") }
    try press("Resume Download")
    try wait("both completed") {
        nodes(app).filter { text($0, kAXRoleAttribute) == "AXStaticText" && text($0, kAXValueAttribute) == "Completed" }.count == 2
    }
    print("UI PASS: MP4 pause/resume and completion through native controls")
    try press("Failed")
    try wait("failed empty state") { containsText("There are no failed downloads.") }
    try press("All Downloads")
    print("UI PASS: sidebar filters")
}
