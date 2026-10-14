import Foundation

/// Renders Atlassian Document Format as the HTML ADO shows; media is skipped (attachments carry it).
func adfToHTML(_ doc: Any?) -> String {
    guard let n = doc as? JSONObject else { return "" }
    var out = ""
    renderADF(n, into: &out)
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func renderADF(_ n: JSONObject, into b: inout String) {
    let content = n["content"] as? [JSONObject] ?? []
    func inner() { for c in content { renderADF(c, into: &b) } }
    func wrap(_ tag: String) {
        b += "<\(tag)>"
        inner()
        b += "</\(tag)>"
    }
    switch n["type"] as? String ?? "" {
    case "paragraph": wrap("p")
    case "heading":
        let level = number((n["attrs"] as? JSONObject)?["level"]).map { Int($0) } ?? 1
        wrap("h\(min(max(level, 1), 6))")
    case "text": b += applyMarks(n["text"] as? String ?? "", n["marks"] as? [JSONObject] ?? [])
    case "hardBreak": b += "<br/>"
    case "bulletList": wrap("ul")
    case "orderedList": wrap("ol")
    case "listItem": wrap("li")
    case "blockquote": wrap("blockquote")
    case "codeBlock":
        b += "<pre><code>"
        inner()
        b += "</code></pre>"
    case "rule": b += "<hr/>"
    case "mention": b += escapeHTML(attr(n, "text", "@" + attr(n, "id", "")))
    case "emoji": b += escapeHTML(attr(n, "text", attr(n, "shortName", "")))
    case "inlineCard":
        let u = escapeHTML(attr(n, "url", ""))
        b += "<a href=\"\(u)\">\(u)</a>"
    default: inner()  // doc, media*, unknown: their children only
    }
}

private func applyMarks(_ text: String, _ marks: [JSONObject]) -> String {
    var out = escapeHTML(text)
    for m in marks {
        switch m["type"] as? String ?? "" {
        case "strong": out = "<strong>\(out)</strong>"
        case "em": out = "<em>\(out)</em>"
        case "code": out = "<code>\(out)</code>"
        case "strike": out = "<s>\(out)</s>"
        case "underline": out = "<u>\(out)</u>"
        case "link": out = "<a href=\"\(escapeHTML(attr(m, "href", "")))\">\(out)</a>"
        default: break
        }
    }
    return out
}

private func attr(_ n: JSONObject, _ key: String, _ def: String) -> String {
    if let s = (n["attrs"] as? JSONObject)?[key] as? String, !s.isEmpty { return s }
    return def
}

/// &, < and > only, as the source app (quotes untouched).
func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
}
