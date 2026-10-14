package syncer

import (
	"encoding/json"
	"fmt"
	"strings"
)

type adfNode struct {
	Type    string         `json:"type"`
	Text    string         `json:"text"`
	Attrs   map[string]any `json:"attrs"`
	Marks   []adfNode      `json:"marks"`
	Content []adfNode      `json:"content"`
}

// adfToHTML renders Atlassian Document Format as the HTML ADO shows; media is skipped (attachments carry it).
func adfToHTML(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var n adfNode
	if json.Unmarshal(raw, &n) != nil {
		return ""
	}
	var b strings.Builder
	render(&b, n)
	return strings.TrimSpace(b.String())
}

func render(b *strings.Builder, n adfNode) {
	inner := func() {
		for _, c := range n.Content {
			render(b, c)
		}
	}
	wrap := func(tag string) {
		fmt.Fprintf(b, "<%s>", tag)
		inner()
		fmt.Fprintf(b, "</%s>", tag)
	}
	switch n.Type {
	case "paragraph":
		wrap("p")
	case "heading":
		level, _ := n.Attrs["level"].(float64)
		wrap(fmt.Sprintf("h%d", min(max(int(level), 1), 6)))
	case "text":
		b.WriteString(applyMarks(n.Text, n.Marks))
	case "hardBreak":
		b.WriteString("<br/>")
	case "bulletList":
		wrap("ul")
	case "orderedList":
		wrap("ol")
	case "listItem":
		wrap("li")
	case "blockquote":
		wrap("blockquote")
	case "codeBlock":
		b.WriteString("<pre><code>")
		inner()
		b.WriteString("</code></pre>")
	case "rule":
		b.WriteString("<hr/>")
	case "mention":
		b.WriteString(escape(attr(n, "text", "@"+attr(n, "id", ""))))
	case "emoji":
		b.WriteString(escape(attr(n, "text", attr(n, "shortName", ""))))
	case "inlineCard":
		u := escape(attr(n, "url", ""))
		fmt.Fprintf(b, `<a href="%s">%s</a>`, u, u)
	default: // doc, media*, unknown: their children only
		inner()
	}
}

func applyMarks(text string, marks []adfNode) string {
	out := escape(text)
	for _, m := range marks {
		switch m.Type {
		case "strong":
			out = "<strong>" + out + "</strong>"
		case "em":
			out = "<em>" + out + "</em>"
		case "code":
			out = "<code>" + out + "</code>"
		case "strike":
			out = "<s>" + out + "</s>"
		case "underline":
			out = "<u>" + out + "</u>"
		case "link":
			out = fmt.Sprintf(`<a href="%s">%s</a>`, escape(attr(m, "href", "")), out)
		}
	}
	return out
}

func attr(n adfNode, key, def string) string {
	if s, ok := n.Attrs[key].(string); ok && s != "" {
		return s
	}
	return def
}

// escape matches the source app: &, < and > only (html.EscapeString would also touch quotes).
func escape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}
