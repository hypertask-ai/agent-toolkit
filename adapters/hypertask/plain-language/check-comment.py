#!/usr/bin/env python3
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlparse


class Node:
    def __init__(self, tag, attrs):
        self.tag = tag.casefold()
        self.attrs = {name.casefold(): value or "" for name, value in attrs}
        self.children = []


class FragmentParser(HTMLParser):
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.roots = []
        self.stack = []
        self.errors = []

    def add(self, value):
        target = self.stack[-1].children if self.stack else self.roots
        target.append(value)

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.add(node)
        if node.tag not in self.VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.add(Node(tag, attrs))

    def handle_endtag(self, tag):
        wanted = tag.casefold()
        if not self.stack or self.stack[-1].tag != wanted:
            self.errors.append("HTML blocks are not properly nested")
            return
        self.stack.pop()

    def handle_data(self, data):
        self.add(data)

    def close(self):
        super().close()
        if self.stack:
            self.errors.append("HTML blocks are not closed")


def visible(node):
    if isinstance(node, str):
        return node
    return "".join(visible(child) for child in node.children)


def unlinked_visible(node):
    if isinstance(node, str):
        return node
    if node.tag == "a":
        return ""
    return "".join(unlinked_visible(child) for child in node.children)


def meaningful(children):
    return [child for child in children if not isinstance(child, str) or child.strip()]


def references(node, anchor=None):
    if isinstance(node, str):
        yield node, anchor
        return
    current = node if node.tag == "a" else anchor
    for child in node.children:
        yield from references(child, current)


def check(raw):
    reasons = []
    parser = FragmentParser()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:
        reasons.append("comment is not valid HTML")
        return reasons
    reasons.extend(parser.errors)

    roots = meaningful(parser.roots)
    if not roots or isinstance(roots[0], str) or roots[0].tag != "p":
        reasons.append("first block must be a <p>")
    else:
        first_children = meaningful(roots[0].children)
        if not first_children or isinstance(first_children[0], str) or first_children[0].tag != "strong":
            reasons.append("first sentence must be bold")
        else:
            strong = first_children[0]
            lead = " ".join(visible(strong).split())
            if not re.search(r"[.!?](?:[\"']?)$", lead):
                reasons.append("the bold lead must contain the complete first sentence")
            marker = re.match(r"(Done|Handoff):\s*(.*)", lead, re.IGNORECASE)
            if marker:
                unlinked = " ".join(unlinked_visible(strong).split())
                explanation = re.sub(r"^(?:Done|Handoff):\s*", "", unlinked, flags=re.IGNORECASE)
                if not re.search(r"[A-Za-z0-9]", explanation):
                    reasons.append("Done and Handoff must explain what shipped, not only link to it")

    text = " ".join(visible(item) for item in roots)
    text = " ".join(text.split())
    if len(text.split()) > 80:
        reasons.append("comment must be at most 80 words")
    if re.search(r"src/|\.(?:ts|tsx|py|cjs|mjs)\b", text, re.IGNORECASE):
        reasons.append("comment contains a file path")
    if re.search(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\(\s*\)", text) or re.search(
        r"\b[a-z]+(?:[A-Z][A-Za-z0-9]*)+\s*\([^)]*\)", text
    ):
        reasons.append("comment contains a function call")
    if "`" in raw or re.search(r"<\s*code\b", raw, re.IGNORECASE):
        reasons.append("comment contains a code span")
    if re.search(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{7,}(?![0-9A-Fa-f])", text):
        reasons.append("comment contains a commit hash")
    if "—" in raw:
        reasons.append("comment contains an em dash")

    reference = re.compile(r"\b(?:HTPR|AGTE)-\d+\b|\bPR(?:\s*#?\s*|-)\d+\b", re.IGNORECASE)
    for root in roots:
        for part, anchor in references(root):
            href = anchor.attrs.get("href", "") if anchor else ""
            parsed = urlparse(href)
            if reference.search(part) and not (parsed.scheme == "https" and parsed.netloc):
                reasons.append("every ticket or PR reference must be inside a full https link")
                break
        else:
            continue
        break

    if roots:
        last = " ".join(visible(roots[-1]).split())
        if not (last.endswith("?") or last.startswith("Next:")):
            reasons.append('last block must end with a question mark or start with "Next:"')

    return list(dict.fromkeys(reasons))


if __name__ == "__main__":
    failures = check(sys.stdin.read())
    if failures:
        print("\n".join(failures))
        sys.exit(1)
