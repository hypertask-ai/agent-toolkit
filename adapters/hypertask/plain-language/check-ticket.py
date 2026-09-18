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
        (self.stack[-1].children if self.stack else self.roots).append(value)

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
            self.errors.append("description HTML is not properly nested")
            return
        self.stack.pop()

    def handle_data(self, data):
        self.add(data)

    def close(self):
        super().close()
        if self.stack:
            self.errors.append("description HTML has unclosed blocks")


HEADINGS = {"what went wrong", "what changes", "done when", "where things are"}
REFERENCE = re.compile(r"\b(?:HTPR|AGTE)-\d+\b", re.IGNORECASE)


def visible(node):
    if isinstance(node, str):
        return node
    return "".join(visible(child) for child in node.children)


def meaningful(nodes):
    return [node for node in nodes if not isinstance(node, str) or node.strip()]


def heading(node):
    if isinstance(node, str):
        return ""
    text = " ".join(visible(node).split()).casefold().rstrip(":")
    if node.tag in {"h1", "h2", "h3", "h4", "h5", "h6"} and text in HEADINGS:
        return text
    children = meaningful(node.children)
    if node.tag == "p" and len(children) == 1 and not isinstance(children[0], str) and children[0].tag == "strong" and text in HEADINGS:
        return text
    return ""


def references(node, anchor=None):
    if isinstance(node, str):
        yield node, anchor
        return
    current = node if node.tag == "a" else anchor
    for child in node.children:
        yield from references(child, current)


def check(title, raw):
    failures = []
    clean_title = " ".join(title.split())
    if not clean_title:
        failures.append("title is missing")
    elif len(clean_title) > 80:
        failures.append("title is over 80 characters after the rewrite")
    if re.match(r"^(?:bug|change):", clean_title, re.IGNORECASE):
        failures.append("title has a bug: or change: prefix")

    parser = FragmentParser()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:
        failures.append("description is not valid HTML")
        return failures
    failures.extend(parser.errors)
    roots = meaningful(parser.roots)

    if not roots or isinstance(roots[0], str) or roots[0].tag != "p":
        failures.append("bold outcome line is missing")
    else:
        children = meaningful(roots[0].children)
        if len(children) != 1 or isinstance(children[0], str) or children[0].tag != "strong" or not visible(children[0]).strip():
            failures.append("bold outcome line is missing")
        elif not re.search(r"[.!?][\"']?$", visible(children[0]).strip()):
            failures.append("bold outcome line is not a complete sentence")

    positions = {}
    for index, node in enumerate(roots):
        name = heading(node)
        if name and name not in positions:
            positions[name] = index
    for name in ("what went wrong", "what changes", "done when"):
        if name not in positions:
            failures.append("%s section is missing" % name.title())
    if all(name in positions for name in ("what went wrong", "what changes", "done when")):
        if not (positions["what went wrong"] < positions["what changes"] < positions["done when"]):
            failures.append("ticket sections are out of order")
        wrong_at = positions["what went wrong"]
        changes_at = positions["what changes"]
        done_at = positions["done when"]
        wrong_text = " ".join(visible(node) for node in roots[wrong_at + 1:changes_at]).strip()
        sentence_count = len(re.findall(r"[.!?](?:[\"']?)(?:\s|$)", wrong_text))
        if not wrong_text or sentence_count not in range(1, 4):
            failures.append("What went wrong must contain one to three sentences")
        lists = [node for node in roots[changes_at + 1:done_at] if not isinstance(node, str) and node.tag == "ol"]
        if not lists or not any(not isinstance(child, str) and child.tag == "li" for child in lists[0].children):
            failures.append("What changes numbered list is missing")
        if "where things are" in positions and positions["where things are"] < done_at:
            failures.append("Where things are section is out of order")
        next_heading = min(
            (index for index in range(done_at + 1, len(roots)) if heading(roots[index])),
            default=len(roots),
        )
        done_text = " ".join(visible(node) for node in roots[done_at + 1:next_heading]).strip()
        if not done_text:
            failures.append("Done when checkable condition is missing")

    if "—" in clean_title or "—" in raw:
        failures.append("ticket contains an em dash")
    for root in roots:
        for text, anchor in references(root):
            if not REFERENCE.search(text):
                continue
            href = anchor.attrs.get("href", "") if anchor else ""
            parsed = urlparse(href)
            if parsed.scheme != "https" or not parsed.netloc:
                failures.append("every ticket reference must be a clickable https link")
                break
        else:
            continue
        break
    return list(dict.fromkeys(failures))


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: check-ticket.py <title> [html-file]", file=sys.stderr)
        sys.exit(2)
    try:
        body = open(sys.argv[2], encoding="utf-8").read() if len(sys.argv) == 3 else sys.stdin.read()
    except OSError as error:
        print("description could not be read: %s" % error, file=sys.stderr)
        sys.exit(2)
    failures = check(sys.argv[1], body)
    if failures:
        print("\n".join(failures))
        sys.exit(1)
