#!/usr/bin/env python3
"""Firmen-Wiki Linux-Server (Orange Pi PC / Armbian).

Port von tools/editor-server.ps1 auf Python-Standardbibliothek (keine
Abhaengigkeiten), lauffaehig auf ARMv7/armhf mit system-python3.

Aufruf:
    python3 server/wiki_server.py [--port 8765] [--bind 0.0.0.0] [--root /opt/wiki]

API ist absichtlich kompatibel zum Windows-Server (gleiche Routen,
gleiche JSON-Formen, gleiche Dateiformate unter content/, config/).
"""
import argparse
import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ALL_PERMISSIONS = [
    "articles.view", "articles.create", "articles.edit", "articles.delete",
    "articles.archive", "articles.suggest", "articles.requestDelete",
    "products.view", "products.create", "products.edit", "products.delete",
    "products.archive", "products.requestDelete",
    "categories.manage", "categories.assign", "users.manage", "roles.manage",
]
DEFAULT_ROLES = {
    "Administrator": sorted(ALL_PERMISSIONS),
    "Bearbeiter": sorted([
        "articles.view", "articles.create", "articles.edit",
        "articles.suggest", "articles.requestDelete", "products.view", "products.edit",
        "products.requestDelete", "categories.assign",
    ]),
    "Read-Only": sorted(["articles.view", "articles.suggest"]),
}
SESSION_LIFETIME = timedelta(hours=12)
LOCK_LIFETIME = timedelta(minutes=15)
USERNAME_RE = re.compile(r"^[a-z0-9._-]{3,40}$")
ROLENAME_RE = re.compile(r"^[A-Za-z0-9._-]{3,40}$")


class WikiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class AuthError(WikiError):
    def __init__(self, message="Bitte zuerst anmelden."):
        super().__init__(403, message)


# ---------- helpers ----------
def now_local():
    return datetime.now().astimezone()


def iso_now():
    return now_local().isoformat()


def slugify(text):
    s = (text or "").lower()
    s = s.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s or "artikel"


def sanitize_line(value):
    if value is None:
        return ""
    s = re.sub(r"\r?\n", " ", str(value))
    s = re.sub(r"\s+", " ", s).strip()
    return s


def sanitize_filename(value):
    name = os.path.basename(sanitize_line(value)) or "datei"
    name = re.sub(r"[^\w.\- ]", "_", name, flags=re.UNICODE).strip()
    return name or "datei"


def atomic_write_text(path: Path, text: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8", newline="\n")
    os.replace(tmp, path)


def atomic_write_bytes(path: Path, data: bytes):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / (path.name + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def atomic_write_json(path: Path, obj):
    atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2))


def read_json(path: Path, default):
    try:
        if not path.exists():
            return default
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as e:
        raise WikiError(400, f"Datei ungueltig ({path.name}): {e}")


def normalize_category(cat):
    c = sanitize_line(cat)
    if not c:
        return "Wiki Anleitung"
    mapping = {
        "Allgemein": "Wiki Anleitung",
        "Wiki Pflege": "Wiki Anleitung",
        "Wikipflege": "Wiki Anleitung",
        "HR & Organisation": "Wiki Anleitung",
        "HR & Organisierung": "Wiki Anleitung",
        "IT & Systeme": "IT&Systeme",
    }
    return mapping.get(c.strip(), c.strip())


def split_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        out = []
        for v in value:
            v = sanitize_line(v)
            if v:
                out.append(v)
        return out
    s = str(value).strip().strip("[]")
    out = []
    for part in s.split(","):
        p = part.strip().strip('"').strip("'")
        if p:
            out.append(p)
    return out


def related_slugs(value):
    """Normalisiert eine related-Liste (String oder Liste) ohne Duplikate."""
    out = []
    for item in (value if isinstance(value, list) else split_list(value)):
        slug = slugify(item)
        if slug and slug not in out:
            out.append(slug)
    return out


def replace_frontmatter_related(raw, related):
    """Ersetzt nur das related-Feld im Frontmatter, Rest bleibt unveraendert."""
    value = ", ".join(related_slugs(related))
    m = re.match(r"(?s)^(---\r?\n)(.*?)(\r?\n---(?:\r?\n|$))(.*)$", raw or "")
    if not m:
        return raw
    opening, frontmatter, closing, body = m.groups()
    newline = "\r\n" if "\r\n" in opening else "\n"
    lines, found = [], False
    for line in re.split(r"\r?\n", frontmatter):
        if re.match(r"^\s*related\s*:", line, flags=re.IGNORECASE):
            if not found:
                lines.append(f"related: {value}")
                found = True
            continue
        lines.append(line)
    if not found:
        lines.append(f"related: {value}")
    return opening + newline.join(lines) + closing + body


# ---------- markdown (vereinfachter, frontend-kompatibler Renderer) ----------
def safe_local_href(href):
    if not href or not href.strip():
        return False
    h = href.strip()
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", h):
        return False
    if re.match(r"^\s*(/|\\\\)", h):
        return False
    if re.match(r"^(content/uploads/|assets/|data/|\./|\.\./)", h):
        return True
    return bool(re.search(r"/[^/]+\.[A-Za-z0-9]{2,8}$", h))


_SPAN_TOKEN_RE = re.compile(r'<span\s+style="([^"]*)"\s*>|</span\s*>', re.I)
_SPAN_PREFIX_RE = re.compile(r'^\s*((?:<span\s+style="[^"]*"\s*>)*)(.*)$', re.I)


def sanitize_span_style(style):
    """Erlaubt nur color/font-size mit sicheren Werten (wie im Client)."""
    out = []
    for declaration in str(style or "").split(";"):
        colon = declaration.find(":")
        if colon < 0:
            continue
        prop = declaration[:colon].strip().lower()
        value = declaration[colon + 1:].strip()
        if not value or re.search(r'["<>]', value):
            continue
        if prop == "color" and re.fullmatch(
                r'#[0-9a-f]{3,8}|rgba?\([^)]*\)|[a-z]+', value, re.I):
            out.append(f"color: {value}")
        elif prop == "font-size" and re.fullmatch(
                r'\d+(\.\d+)?(rem|px|em|%)|small|medium|large|x-small|x-large|'
                r'xx-small|xx-large|smaller|larger', value, re.I):
            out.append(f"font-size: {value}")
    return "; ".join(out)


def _inline_md_core(text, slug_lookup):
    # schneller Pfad ohne Markup
    if ("[" not in text and "*" not in text and "`" not in text
            and "<span" not in text and "~~" not in text):
        return html.escape(text)
    enc = html.escape(text)
    # Bilder ![alt](href){width=N caption="..."} -> figure/figcaption
    # enc ist HTML-escapet: Anfuehrungszeichen stehen als &quot; da.
    def _img(m):
        alt, href, attrs = m.group(1), html.unescape(m.group(2)).strip(), (m.group(3) or "")
        if not safe_local_href(href):
            return m.group(0)
        wm = re.search(r"width\s*=\s*([0-9]+)", attrs)
        cm = re.search(r'caption\s*=\s*(?:"([^"]*)"|&quot;(.*?)&quot;)', attrs)
        raw_cap = ""
        if cm:
            raw_cap = cm.group(1) if cm.group(1) is not None else (cm.group(2) or "")
        # raw_cap stammt aus escapetem Text: dekodieren, dann sicher kodieren.
        caption = html.escape(html.unescape(raw_cap), quote=True)
        style = ""
        if wm:
            w = min(max(int(wm.group(1)), 80), 1200)
            style = f' style="width: {w}px; max-width: 100%;"'
        img = f'<img src="{html.escape(href)}" alt="{html.escape(alt) or "Bild"}"{style}>'
        if raw_cap:
            return f'<figure class="wiki-figure">{img}<figcaption>{caption}</figcaption></figure>'
        return img
    enc = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)(?:\{([^}]*)\})?", _img, enc)
    # Wikilinks [[Ziel|Label]] / [[Ziel]]
    def _wl2(m):
        target = slugify(html.unescape(m.group(1).strip()))
        label = m.group(2).strip()
        if target in slug_lookup:
            return f'<a href="#/artikel/{target}">{label}</a>'
        return f'<span class="missing-link">{label}</span>'
    enc = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", _wl2, enc)

    def _wl1(m):
        raw = html.unescape(m.group(1).strip())
        target = slugify(raw)
        if target in slug_lookup:
            return f'<a href="#/artikel/{target}">{html.escape(raw)}</a>'
        return f'<span class="missing-link">{html.escape(raw)}</span>'
    enc = re.sub(r"\[\[([^\]]+)\]\]", _wl1, enc)

    def _link(m):
        label, href = m.group(1), html.unescape(m.group(2)).strip()
        if re.match(r"^(https?:|mailto:)", href) or safe_local_href(href):
            return (f'<a href="{html.escape(href)}" target="_blank" '
                    f'rel="noreferrer">{label}</a>')
        return f'<a href="#/artikel/{slugify(href)}">{label}</a>'
    enc = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", _link, enc)
    enc = re.sub(r"`([^`]+)`", r"<code>\1</code>", enc)
    enc = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", enc)
    enc = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", enc)
    enc = re.sub(r"~~([^~]+)~~", r"<s>\1</s>", enc)
    return enc


def inline_md(text, slug_lookup):
    """Markdown-Inlineformatierung inkl. sicherer Style-Spans.

    Span-Tags werden vor der Markdown-Verarbeitung durch eindeutige
    Platzhalter ersetzt. Dadurch funktionieren Inline-Formate wie **fett**
    oder ~~weg~~ auch ueber eine Span-Grenze hinweg (z.B. fett + Farbe).
    """
    text = str(text or "")
    lower = text.lower()
    if "<span" not in lower and "</span" not in lower:
        return _inline_md_core(text, slug_lookup)
    tokens = []
    stack = []
    nonce = secrets.token_hex(8)

    def placeholder(index):
        return f"\x00{nonce}{index}\x00"

    def replace_span(m):
        if m.group(1) is not None:
            clean = sanitize_span_style(m.group(1))
            if not clean:
                stack.append(False)
                return ""
            tokens.append(f'<span style="{html.escape(clean, quote=True)}">')
            stack.append(True)
            return placeholder(len(tokens) - 1)
        if not stack:
            return ""
        if not stack.pop():
            return ""
        tokens.append("</span>")
        return placeholder(len(tokens) - 1)

    protected = _SPAN_TOKEN_RE.sub(replace_span, text)
    rendered = _inline_md_core(protected, slug_lookup)
    # Platzhalter nur in Textknoten einsetzen, nicht in generierten
    # HTML-Attributen (z.B. Bild-alt). Dort werden sie entfernt.
    parts = re.split(r"(<[^>]*>)", rendered)
    for pos, part in enumerate(parts):
        if part.startswith("<") and part.endswith(">"):
            parts[pos] = re.sub(r"\x00[^\x00]*\x00", "", part)
        else:
            for index, token in enumerate(tokens):
                part = part.replace(placeholder(index), token)
            parts[pos] = part
    rendered = "".join(parts)
    for kept in reversed(stack):
        if kept:
            rendered += "</span>"
    return rendered


def split_leading_spans(line):
    m = _SPAN_PREFIX_RE.match(line or "")
    if not m:
        return "", line or ""
    return m.group(1), m.group(2)


def match_list_line(line):
    spans, rest = split_leading_spans(line)
    m = re.match(r"^\s*(\d+)([.)])\s+(.+)$", rest)
    if m:
        return "ol", spans + m.group(3)
    m = re.match(r"^\s*([-*+])\s+(.+)$", rest)
    if m:
        return "ul", spans + m.group(2)
    return None


def match_heading_line(line):
    spans, rest = split_leading_spans(line)
    m = re.match(r"^\s*(#{1,6})\s+(.+)$", rest)
    if not m:
        return None
    return min(len(m.group(1)), 6), spans + m.group(2)


def match_quote_line(line):
    spans, rest = split_leading_spans(line)
    m = re.match(r"^\s*>\s+(.+)$", rest)
    if not m:
        return None
    return spans + m.group(1)


def markdown_to_html(md, slug_lookup):
    lines = re.split(r"\r?\n", md or "")
    out = []
    in_code = in_ul = in_ol = False
    pending_br = False

    def close_lists():
        nonlocal in_ul, in_ol
        if in_ul:
            out.append("</ul>")
            in_ul = False
        if in_ol:
            out.append("</ol>")
            in_ol = False

    i = 0
    while i < len(lines):
        line = lines[i]
        hard = False
        if not in_code and re.search(r"\\\s*$", line):
            line = re.sub(r"\\\s*$", "", line)
            hard = True
        if re.match(r"^\s*<!--.*-->\s*$", line):
            pending_br = False
            i += 1
            continue
        if re.match(r"^\s*```", line):
            close_lists()
            pending_br = False
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                out.append("<pre><code>")
                in_code = True
            i += 1
            continue
        if in_code:
            pending_br = False
            out.append(html.escape(line))
            i += 1
            continue
        # Tabelle
        if ("|" in line and i + 1 < len(lines) and re.match(
                r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$", lines[i + 1])):
            close_lists()
            pending_br = False
            headers = [c.strip() for c in line.strip().strip("|").split("|")]
            out.append("<table><thead><tr>")
            for h in headers:
                out.append(f"<th>{inline_md(h, slug_lookup)}</th>")
            out.append("</tr></thead><tbody>")
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                # Reihe als <tr> gruppieren (kompakt, aber gueltig)
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                out.append("<tr>" + "".join(
                    f"<td>{inline_md(c, slug_lookup)}</td>" for c in cells) + "</tr>")
                i += 1
            i -= 1
            out.append("</tbody></table>")
            i += 1
            continue
        if not line.strip():
            close_lists()
            pending_br = False
            i += 1
            continue
        heading = match_heading_line(line)
        if heading:
            close_lists()
            pending_br = False
            lvl, content = heading
            out.append(f"<h{lvl}>{inline_md(content, slug_lookup)}</h{lvl}>")
            i += 1
            continue
        list_line = match_list_line(line)
        if list_line and list_line[0] == "ul":
            pending_br = False
            if in_ol:
                out.append("</ol>")
                in_ol = False
            if not in_ul:
                out.append("<ul>")
                in_ul = True
            out.append(f"<li>{inline_md(list_line[1], slug_lookup)}</li>")
            i += 1
            continue
        if list_line and list_line[0] == "ol":
            pending_br = False
            if in_ul:
                out.append("</ul>")
                in_ul = False
            if not in_ol:
                out.append("<ol>")
                in_ol = True
            out.append(f"<li>{inline_md(list_line[1], slug_lookup)}</li>")
            i += 1
            continue
        quote = match_quote_line(line)
        if quote is not None:
            close_lists()
            pending_br = False
            out.append(f"<blockquote>{inline_md(quote, slug_lookup)}</blockquote>")
            i += 1
            continue
        if re.match(r"^\s*---+\s*$", line):
            close_lists()
            pending_br = False
            out.append("<hr>")
            i += 1
            continue
        close_lists()
        rendered = inline_md(line, slug_lookup)
        if pending_br and out and re.match(r"^<p>.*</p>$", out[-1]):
            out[-1] = out[-1].replace("</p>", f"<br>{rendered}</p>", 1)
        else:
            out.append(f"<p>{rendered}</p>")
        pending_br = hard
        i += 1
    close_lists()
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


# ---------- Wiki-Store ----------
class WikiStore:
    def __init__(self, root: Path):
        self.root = root
        self.articles_dir = root / "content" / "articles"
        self.archive_dir = root / "content" / "archive"
        self.uploads_dir = root / "content" / "uploads"
        self.suggestions_dir = root / "content" / "suggestions"
        self.categories_file = root / "content" / "categories.json"
        self.category_groups_file = root / "content" / "category-groups.json"
        self.products_file = root / "content" / "products.json"
        self.product_archive_file = root / "content" / "product-archive.json"
        self.users_file = root / "config" / "users.json"
        self.roles_file = root / "config" / "roles.json"
        self.data_file = root / "data" / "wiki-data.js"
        self.versions_dir = root / "versions"
        self.backup_dir = root / "versions" / "backups"
        self.lock = threading.RLock()
        self.sessions = {}
        self.article_locks = {}
        for d in [self.articles_dir, self.archive_dir, self.uploads_dir,
                  self.suggestions_dir, self.versions_dir, self.backup_dir,
                  root / "data", root / "runtime", root / "config"]:
            d.mkdir(parents=True, exist_ok=True)
        self.migrate_roles_users()
        self.migrate_suggestions()

    # ----- crypto / users / roles -----
    @staticmethod
    def hash_password(password, salt=None):
        if len(password) < 10:
            raise WikiError(400, "Das Passwort muss mindestens 10 Zeichen lang sein.")
        salt = salt or secrets.token_bytes(16)
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 120000, dklen=32)
        return {"salt": base64.b64encode(salt).decode(),
                "hash": base64.b64encode(dk).decode(),
                "iterations": 120000, "algorithm": "PBKDF2-SHA256"}

    @staticmethod
    def check_password(password, user):
        try:
            salt = base64.b64decode(user["salt"])
            it = int(user.get("iterations", 120000))
            dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, it, dklen=32)
            exp = base64.b64decode(user["passwordHash"])
            return hmac.compare_digest(dk, exp)
        except Exception:
            return False

    def read_users(self):
        with self.lock:
            data = read_json(self.users_file, [])
            return list(data) if isinstance(data, list) else []

    def write_users(self, users):
        with self.lock:
            atomic_write_json(self.users_file, users)

    def read_roles(self):
        with self.lock:
            if not self.roles_file.exists():
                self.write_roles(dict(DEFAULT_ROLES))
                return {k: list(v) for k, v in DEFAULT_ROLES.items()}
            try:
                parsed = json.loads(self.roles_file.read_text(encoding="utf-8-sig"))
            except Exception:
                self.write_roles(dict(DEFAULT_ROLES))
                return {k: list(v) for k, v in DEFAULT_ROLES.items()}
            roles = parsed.get("roles", {}) if isinstance(parsed, dict) else {}
            clean = {}
            for name, perms in roles.items():
                n = sanitize_line(name)
                if not n:
                    continue
                if isinstance(perms, str):
                    perms = [perms]
                clean[n] = sorted({p for p in (perms or []) if p in ALL_PERMISSIONS})
            if not clean:
                self.write_roles(dict(DEFAULT_ROLES))
                return {k: list(v) for k, v in DEFAULT_ROLES.items()}
            return clean

    def write_roles(self, roles):
        with self.lock:
            atomic_write_json(self.roles_file, {"roles": roles})

    def role_perms(self, role):
        return self.read_roles().get(role, [])

    def migrate_roles_users(self):
        roles = self.read_roles()
        changed = False
        mapping = {"Redakteur": "Bearbeiter", "Leser": "Read-Only"}
        for old, new in mapping.items():
            if old in roles and new not in roles:
                merged = sorted({*roles.pop(old), *DEFAULT_ROLES.get(new, [])})
                merged = [p for p in merged if p in ALL_PERMISSIONS]
                roles[new] = merged
                changed = True
        if "Administrator" in roles:
            for p in ("articles.suggest", "articles.requestDelete", "products.requestDelete"):
                if p not in roles["Administrator"]:
                    roles["Administrator"] = sorted([*roles["Administrator"], p])
                    changed = True
        if ("Bearbeiter" in roles and "articles.requestDelete" in roles["Bearbeiter"]
                and "products.requestDelete" not in roles["Bearbeiter"]):
            roles["Bearbeiter"] = sorted([*roles["Bearbeiter"], "products.requestDelete"])
            changed = True
        # Bearbeiter: Aenderungsvorschlaege einreichen (Vorschlags-Ampel, nur additiv).
        if "Bearbeiter" in roles and "articles.suggest" not in roles["Bearbeiter"]:
            roles["Bearbeiter"] = sorted([*roles["Bearbeiter"], "articles.suggest"])
            changed = True
        # Produktgruppe anlegen/zuordnen: Admin + Bearbeiter (nur additiv).
        for rn in ("Administrator", "Bearbeiter"):
            if rn in roles and "categories.assign" not in roles[rn]:
                roles[rn] = sorted([*roles[rn], "categories.assign"])
                changed = True
        if "Read-Only" in roles and "products.view" in roles["Read-Only"]:
            roles["Read-Only"] = [p for p in roles["Read-Only"] if p != "products.view"]
            changed = True
        if changed:
            self.write_roles(roles)
        users = self.read_users()
        uchanged = False
        for u in users:
            if u.get("role") in mapping and mapping[u["role"]] in roles:
                u["role"] = mapping[u["role"]]
                uchanged = True
        if uchanged:
            self.write_users(users)

    # ----- sessions / locks -----
    def sweep(self):
        t = now_local()
        for tok in [k for k, s in self.sessions.items() if s["expiresAt"] < t]:
            self.sessions.pop(tok, None)
        for slug in [k for k, s in self.article_locks.items() if s["expiresAt"] < t]:
            self.article_locks.pop(slug, None)

    def new_session(self, user):
        token = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
        s = {"token": token, "username": user["username"],
             "displayName": user.get("displayName", user["username"]),
             "role": user.get("role", "Read-Only"),
             "createdAt": now_local(), "expiresAt": now_local() + SESSION_LIFETIME}
        with self.lock:
            self.sessions[token] = s
        return s

    def session_from_token(self, token):
        with self.lock:
            self.sweep()
            s = self.sessions.get(token)
            if not s:
                return None
            s["expiresAt"] = now_local() + SESSION_LIFETIME
            return s

    def assert_perm(self, session, perms):
        if session is None:
            raise AuthError()
        have = self.role_perms(session["role"])
        for p in perms:
            if p not in have:
                raise AuthError("Fuer diese Aktion fehlt die Berechtigung.")

    def assert_cat_assign(self, session):
        # Produktgruppe anlegen/zuordnen: categories.assign genuegt,
        # categories.manage schliesst das Recht immer mit ein.
        if session is None:
            raise AuthError()
        have = self.role_perms(session["role"])
        if "categories.assign" not in have and "categories.manage" not in have:
            raise AuthError("Fuer diese Aktion fehlt die Berechtigung.")

    def public_locks(self):
        with self.lock:
            self.sweep()
            return [{"slug": v["slug"], "username": v["username"],
                     "displayName": v["displayName"],
                     "acquiredAt": v["acquiredAt"].isoformat(),
                     "expiresAt": v["expiresAt"].isoformat()}
                    for v in self.article_locks.values()]

    def acquire_lock(self, slug, session):
        self.assert_perm(session, ["articles.edit"])
        with self.lock:
            self.sweep()
            ex = self.article_locks.get(slug)
            if ex and ex["username"] != session["username"]:
                raise WikiError(409, f"Der Artikel wird seit "
                    f"{ex['acquiredAt'].strftime('%d.%m.%Y %H:%M')} von "
                    f"{ex['displayName']} bearbeitet.")
            lk = {"slug": slug, "username": session["username"],
                  "displayName": session["displayName"],
                  "acquiredAt": ex["acquiredAt"] if ex else now_local(),
                  "expiresAt": now_local() + LOCK_LIFETIME}
            self.article_locks[slug] = lk
            return {"slug": slug, "username": lk["username"],
                    "displayName": lk["displayName"],
                    "acquiredAt": lk["acquiredAt"].isoformat(),
                    "expiresAt": lk["expiresAt"].isoformat()}

    def assert_lock(self, slug, session):
        with self.lock:
            self.sweep()
            lk = self.article_locks.get(slug)
            if not lk or lk["username"] != session["username"]:
                raise WikiError(403, "Der Artikel ist nicht fuer diese Sitzung "
                                     "gesperrt. Oeffne die Bearbeitung erneut.")
            lk["expiresAt"] = now_local() + LOCK_LIFETIME

    def release_lock(self, slug, session, force=False):
        with self.lock:
            lk = self.article_locks.get(slug)
            if lk and (force or (session and lk["username"] == session["username"])):
                self.article_locks.pop(slug, None)

    def release_user_locks(self, username):
        with self.lock:
            for slug in [k for k, v in self.article_locks.items()
                         if v["username"] == username]:
                self.article_locks.pop(slug, None)

    # ----- frontmatter / artikel -----
    @staticmethod
    def parse_frontmatter(text):
        meta, body = {}, text
        if text.startswith("---"):
            m = re.match(r"(?s)^---\r?\n(.*?)\r?\n---\r?\n?(.*)$", text)
            if m:
                for line in re.split(r"\r?\n", m.group(1)):
                    if not line.strip():
                        continue
                    pm = re.match(r"^\s*([A-Za-z0-9_-]+)\s*:\s*(.*?)\s*$", line)
                    if pm:
                        meta[pm.group(1).lower()] = pm.group(2).strip().strip('"')
                body = m.group(2).strip()
        return meta, body

    @staticmethod
    def revision_of(meta):
        try:
            return max(1, int(str(meta.get("revision", 1))))
        except Exception:
            return 1

    @staticmethod
    def remove_revision_log(body):
        return re.sub(r"(?s)\r?\n?<!-- WIKI_REVISION_LOG_START -->.*?<!-- WIKI_REVISION_LOG_END -->\r?\n?",
                      "", body or "").strip()

    @staticmethod
    def revision_log(body):
        m = re.search(r"(?s)<!-- WIKI_REVISION_LOG_START -->(.*?)<!-- WIKI_REVISION_LOG_END -->",
                      body or "")
        return m.group(0) if m else ""

    @staticmethod
    def add_revision_entry(body, existing_log, revision, action, reason, changed_by):
        clean = WikiStore.remove_revision_log(body)
        stamp = now_local().strftime("%Y-%m-%d %H:%M")
        entry = f"- {stamp}: Revision {revision}, {action} durch {changed_by}. Grund: {reason}"
        log = existing_log.strip() or ("<!-- WIKI_REVISION_LOG_START -->\n"
                                       "## Revisionsverlauf\n"
                                       "<!-- WIKI_REVISION_LOG_END -->")
        if "<!-- WIKI_REVISION_LOG_END -->" in log:
            log = log.replace("<!-- WIKI_REVISION_LOG_END -->",
                              entry + "\n<!-- WIKI_REVISION_LOG_END -->")
        else:
            log = log + "\n" + entry
        return (clean + "\n\n" + log).strip()

    def find_article(self, slug):
        with self.lock:
            if not self.articles_dir.exists():
                return None
            for f in sorted(self.articles_dir.glob("*.md")):
                try:
                    raw = f.read_text(encoding="utf-8-sig")
                except Exception:
                    continue
                meta, body = self.parse_frontmatter(raw)
                title = meta.get("title", f.stem)
                aslug = slugify(meta.get("slug", title))
                if aslug == slug:
                    return {"file": f, "raw": raw, "meta": meta,
                            "body": body, "slug": aslug, "title": title}
        return None

    def read_active_related_map(self):
        """Slug -> direkt gespeicherte related-Slugs aller aktiven Artikel."""
        result = {}
        with self.lock:
            if not self.articles_dir.exists():
                return result
            for f in sorted(self.articles_dir.glob("*.md")):
                try:
                    raw = f.read_text(encoding="utf-8-sig")
                except Exception:
                    continue
                meta, _ = self.parse_frontmatter(raw)
                slug = slugify(meta.get("slug", meta.get("title", f.stem)))
                result[slug] = set(related_slugs(meta.get("related", "")))
        return result

    @staticmethod
    def effective_related(slug, related_map):
        """Direkte Links plus Gegenlinks anderer Artikel (ohne Selbstbezug)."""
        values = list(related_map.get(slug, set()))
        for other, links in related_map.items():
            if other != slug and slug in links and other not in values:
                values.append(other)
        return [x for x in values if x != slug]

    def plan_related_sync(self, current_slug, new_related, base_related=None):
        """Berechnet die beim Speichern noetigen Gegenverknuepfungen.

        new_related   = Auswahl aus dem Formular
        base_related  = Auswahl beim Oeffnen des Editors. Damit werden nur
                        bewusste Aenderungen des Benutzers propagiert und
                        parallel hinzugekommene Links nicht entfernt.
        """
        with self.lock:
            related_map = self.read_active_related_map()
            effective_now = self.effective_related(current_slug, related_map)
            effective_set = set(effective_now)
            if base_related is None:
                base_set = set(effective_now)
            else:
                base_set = {x for x in related_slugs(base_related) if x != current_slug}
            requested = [x for x in related_slugs(new_related) if x != current_slug]
            requested_set = set(requested)
            # Seit dem Oeffnen hinzugekommene (z. B. parallele) Links behalten.
            concurrent = [x for x in effective_now if x not in base_set]
            final = list(requested)
            for slug in concurrent:
                if slug not in final:
                    final.append(slug)
            additions = [x for x in final if x not in effective_set]
            removals = [x for x in base_set if x not in requested_set]
            return final, additions, removals

    def _set_related_membership(self, target_slug, member_slug, present):
        if not target_slug or not member_slug or target_slug == member_slug:
            return False
        target = self.find_article(target_slug)
        if not target:
            return False
        related = related_slugs(target["meta"].get("related", ""))
        if present:
            if member_slug in related:
                return False
            related.append(member_slug)
        else:
            if member_slug not in related:
                return False
            related = [x for x in related if x != member_slug]
        new_raw = replace_frontmatter_related(target["raw"], related)
        if new_raw == target["raw"]:
            return False
        atomic_write_text(target["file"], new_raw)
        return True

    def apply_related_changes(self, current_slug, additions, removals, previous_slug=None):
        """Schreibt nur die Gegenlinks; andere Verknuepfungen bleiben erhalten."""
        with self.lock:
            for target_slug in additions or []:
                self._set_related_membership(target_slug, current_slug, True)
            for target_slug in removals or []:
                self._set_related_membership(target_slug, current_slug, False)
                if previous_slug and previous_slug != current_slug:
                    self._set_related_membership(target_slug, previous_slug, False)

    def rename_related_references(self, old_slug, new_slug):
        """Haelt Links bei einer Titel-/Slug-Aenderung konsistent."""
        if not old_slug or not new_slug or old_slug == new_slug:
            return
        with self.lock:
            if not self.articles_dir.exists():
                return
            for f in sorted(self.articles_dir.glob("*.md")):
                try:
                    raw = f.read_text(encoding="utf-8-sig")
                except Exception:
                    continue
                meta, _ = self.parse_frontmatter(raw)
                if slugify(meta.get("slug", meta.get("title", f.stem))) == new_slug:
                    continue
                related = related_slugs(meta.get("related", ""))
                if old_slug not in related:
                    continue
                changed = []
                for slug in related:
                    replacement = new_slug if slug == old_slug else slug
                    if replacement not in changed:
                        changed.append(replacement)
                new_raw = replace_frontmatter_related(raw, changed)
                if new_raw != raw:
                    atomic_write_text(f, new_raw)

    def filter_article_products(self, data, current_slug):
        # Serverseitig: nur Produkte der gewaehlten Kategorie behalten,
        # Selbst-Verknuepfung bei verwandten Artikeln verhindern.
        try:
            if not isinstance(data, dict):
                return
            cats = []
            for key in ("categories", "category", "categoryIds"):
                if key in data and data[key] is not None:
                    v = data[key]
                    vals = v if isinstance(v, list) else split_list(v)
                    for c in vals:
                        n = normalize_category(c)
                        if n and n not in cats:
                            cats.append(n)
            if "products" in data and cats:
                valid = {p["id"] for p in self.read_products()
                         if any(c in (p.get("categories") or []) for c in cats)}
                seen, kept = set(), []
                for pid in (data.get("products") or []):
                    pid = sanitize_line(pid)
                    if pid and pid in valid and pid not in seen:
                        seen.add(pid)
                        kept.append(pid)
                data["products"] = kept
            if "related" in data:
                seen, kept = set(), []
                for r in (data.get("related") or []):
                    s = slugify(str(r))
                    if s and s != current_slug and s not in seen:
                        seen.add(s)
                        kept.append(s)
                data["related"] = kept
        except Exception:
            pass

    def article_categories(self, data, meta=None):
        cats = []
        if isinstance(data, dict):
            for key in ("categories", "category", "categoryIds"):
                if key in data and data[key] is not None:
                    v = data[key]
                    vals = v if isinstance(v, list) else split_list(v)
                    for c in vals:
                        n = normalize_category(c)
                        if n and n not in cats:
                            cats.append(n)
        if not cats and meta:
            if "categories" in meta:
                for c in split_list(meta["categories"]):
                    n = normalize_category(c)
                    if n and n not in cats:
                        cats.append(n)
            if not cats and "category" in meta and str(meta["category"]).strip():
                cats.append(normalize_category(meta["category"]))
        return cats or ["Wiki Anleitung"]

    # ----- produkte / kategorien -----
    def read_products(self):
        return [self.norm_product(p) for p in read_json(self.products_file, [])
                if sanitize_line(p.get("name") if isinstance(p, dict) else p)
                and sanitize_line((p.get("article") or p.get("artikel", ""))
                                  if isinstance(p, dict) else p)]

    def norm_product(self, p):
        if isinstance(p, str):
            p = {"name": p, "article": p}
        g = lambda *ks: next((sanitize_line(p.get(k, "")) for k in ks
                              if k in p), "")
        name, article, hw = g("name"), g("article", "artikel"), g("hardwareRevision", "hardwarerevision")
        cats = []
        for k in ("categories", "categoryIds"):
            if k in p and p[k] is not None:
                vals = p[k] if isinstance(p[k], list) else split_list(p[k])
                cats = [normalize_category(c) for c in vals]
        try:
            rev = max(1, int(str(p.get("revision", 1))))
        except Exception:
            rev = 1
        dr = None
        if isinstance(p.get("deleteRequest"), dict) and sanitize_line(p["deleteRequest"].get("by")):
            dr = {"by": sanitize_line(p["deleteRequest"].get("by")),
                  "at": sanitize_line(p["deleteRequest"].get("at", "")),
                  "reason": sanitize_line(p["deleteRequest"].get("reason", ""))}
        pid = g("id") or slugify(f"{name}-{article}-{hw}")
        return {"id": pid, "name": name.strip(), "article": article.strip(),
                "hardwareRevision": hw.strip(),
                "description": sanitize_line(p.get("description", "")),
                "categories": [c for c in dict.fromkeys(cats) if c],
                "revision": rev, "status": sanitize_line(p.get("status", "")) or "Aktiv",
                "updated": sanitize_line(p.get("updated", "")),
                "changeDate": sanitize_line(p.get("changeDate", p.get("change_date", ""))),
                "changeAction": sanitize_line(p.get("changeAction", p.get("change_action", ""))),
                "changeReason": sanitize_line(p.get("changeReason", p.get("change_reason", ""))),
                "deleteRequest": dr}

    def write_products(self, items):
        atomic_write_json(self.products_file, items)

    def read_archived_products(self):
        out = []
        for p in read_json(self.product_archive_file, []):
            n = self.norm_product(p)
            if n["name"] and n["article"]:
                n["status"] = n["status"] or "Archiviert"
                out.append(n)
        return out

    def write_archived_products(self, items):
        atomic_write_json(self.product_archive_file, items)

    def read_categories(self):
        out = []
        for c in read_json(self.categories_file, []):
            if isinstance(c, str):
                out.append({"name": normalize_category(c), "products": []})
            elif isinstance(c, dict):
                name = normalize_category(c.get("name", ""))
                prods = c.get("products", c.get("productIds", []))
                prods = prods if isinstance(prods, list) else split_list(prods)
                if name:
                    out.append({"name": name, "products": [sanitize_line(x) for x in prods if sanitize_line(x)]})
        return out

    def write_categories(self, items):
        atomic_write_json(self.categories_file, items)

    def read_category_groups(self):
        out = []
        for g in read_json(self.category_groups_file, []):
            if isinstance(g, str):
                out.append({"name": g.strip(), "categories": []})
            elif isinstance(g, dict):
                cats = g.get("categories", [])
                cats = cats if isinstance(cats, list) else split_list(cats)
                out.append({"name": sanitize_line(g.get("name", "")),
                            "categories": [normalize_category(c) for c in cats if normalize_category(c)]})
        return [g for g in out if g["name"]]

    def write_category_groups(self, items):
        atomic_write_json(self.category_groups_file, items)

    def category_usage(self, name):
        # Verwendung einer Produktgruppe (Loeschpruefung): aktive Artikel + Produkte.
        used_articles, used_products = [], []
        if self.articles_dir.exists():
            for f in sorted(self.articles_dir.glob("*.md")):
                try:
                    meta, _body = self.parse_frontmatter(f.read_text(encoding="utf-8-sig"))
                    cats = split_list(meta.get("categories", "")) or (
                        [meta["category"]] if str(meta.get("category", "")).strip() else [])
                    if name in [normalize_category(c) for c in cats]:
                        used_articles.append(meta.get("title", f.stem))
                except Exception:
                    continue
        for p in self.read_products():
            if name in (p.get("categories") or []):
                used_products.append(p.get("name", ""))
        return used_articles, used_products

    # ----- uploads -----
    # Ablage content/uploads/<artikel-slug>/ (stabile ID). Sicherheit:
    # Allowlist (Bilder, PDF, Office, Text), 8 MB, Magic-Bytes,
    # sanitizter Name, Traversal-Schutz.
    UPLOAD_ALLOWED = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
                      ".svg", ".pdf",
                      ".docx", ".xlsx", ".pptx", ".zip",
                      ".doc", ".xls", ".ppt",
                      ".txt", ".csv", ".md"}
    UPLOAD_MAX_BYTES = 8 * 1024 * 1024

    @staticmethod
    def _upload_bytes_ok(raw: bytes, ext: str):
        try:
            if ext == ".pdf":
                return len(raw) > 4 and raw[:4] == b"%PDF"
            if ext == ".svg":
                return b"<svg" in raw[:512]
            if ext in (".docx", ".xlsx", ".pptx", ".zip"):
                # Office Open XML + ZIP: PK..
                return len(raw) > 4 and raw[:2] == b"PK" and raw[2:4] == b"\x03\x04"
            if ext in (".doc", ".xls", ".ppt"):
                # OLE Compound Document: D0 CF 11 E0 A1 B1 1A E1
                return (len(raw) > 8 and
                        raw[:8] == b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1")
            if ext in (".txt", ".csv", ".md"):
                if not raw:
                    return False
                try:
                    raw.decode("utf-8-sig" if raw[:3] == b"\xef\xbb\xbf" else "utf-8")
                except Exception:
                    return False
                return True
            return WikiStore._image_bytes_ok(raw, ext)
        except Exception:
            return False

    @staticmethod
    def _image_bytes_ok(raw: bytes, ext: str):
        try:
            if ext == ".pdf":
                return len(raw) > 4 and raw[:4] == b"%PDF"
            if ext == ".svg":
                return b"<svg" in raw[:512]
            if len(raw) < 4:
                return False
            png = raw[:4] == b"\x89PNG"
            jpg = len(raw) > 2 and raw[:3] == b"\xff\xd8\xff"
            gif = raw[:3] == b"GIF"
            bmp = raw[:2] == b"BM"
            webp = (len(raw) > 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP")
            if ext == ".png":
                return png
            if ext in (".jpg", ".jpeg"):
                return jpg
            if ext == ".gif":
                return gif
            if ext == ".bmp":
                return bmp
            if ext == ".webp":
                return webp
            return png or jpg or gif or bmp or webp
        except Exception:
            return False

    def save_uploaded_files(self, article_slug, files):
        slug = slugify(article_slug or "medien")
        target = self.uploads_dir / slug
        target.mkdir(parents=True, exist_ok=True)
        target_res = target.resolve()
        saved = []
        for f in files or []:
            if not isinstance(f, dict):
                continue
            name = sanitize_filename(f.get("name", "datei"))
            b64 = str(f.get("data", ""))
            m = re.match(r"^data:[^;]+;base64,(.+)$", b64, re.S)
            if m:
                b64 = m.group(1)
            if not b64.strip():
                continue
            try:
                raw = base64.b64decode(re.sub(r"\s+", "", b64))
            except Exception:
                continue
            if not raw or len(raw) > self.UPLOAD_MAX_BYTES:
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext not in self.UPLOAD_ALLOWED:
                continue
            if not self._upload_bytes_ok(raw, ext):
                continue
            dest = target / (name or "datei")
            stem, ex2 = os.path.splitext(dest.name)
            stem = stem or "datei"
            i = 1
            while dest.exists():
                dest = target / f"{stem}-{i}{ex2}"
                i += 1
                if i > 500:
                    break
            try:
                if target_res not in dest.resolve().parents and dest.resolve() != target_res:
                    continue
            except Exception:
                continue
            dest.write_bytes(raw)
            rel = dest.relative_to(self.root).as_posix()
            saved.append({"path": rel, "name": dest.name})
        return saved

    def inline_base64_to_files(self, body, article_slug):
        # Lagert data:image-URIs nach content/uploads/<slug>/ aus (stabile
        # Artikel-ID, Dedup per SHA12, max. 8 MB).
        if not body or "data:image/" not in body:
            return body
        slug = slugify(article_slug or "medien")
        article_dir = self.uploads_dir / slug
        article_dir.mkdir(parents=True, exist_ok=True)
        mime_map = {"png": "png", "jpg": "jpg", "jpeg": "jpg", "gif": "gif",
                    "webp": "webp", "svg+xml": "svg", "bmp": "bmp"}
        base = re.sub(r"[^a-z0-9]+", "-", slug).strip("-") or "bild"
        base = base[:30]

        def _rep(m):
            mime = m.group(1).strip().lower()
            b64 = re.sub(r"\s+", "", m.group(2))
            if mime not in mime_map or len(b64) % 4 != 0:
                return m.group(0)
            try:
                raw = base64.b64decode(b64)
            except Exception:
                return m.group(0)
            if not raw or len(raw) > 8 * 1024 * 1024:
                return m.group(0)
            sha = hashlib.sha256(raw).hexdigest()[:12]
            name = f"bild-{base}-{sha}.{mime_map[mime]}"
            dest = article_dir / name
            if not dest.exists():
                dest.write_bytes(raw)
            return f"](content/uploads/{slug}/{name})"
        return re.sub(r"\]\(data:image/([^;,\)]+);base64,([A-Za-z0-9+/=\s]+?)\)", _rep, body)

    # ----- artikel-markdown -----
    def new_article_markdown(self, data, revision, action, reason, existing_log=""):
        title = sanitize_line(data.get("title", ""))
        slug = slugify(title)
        cats = self.article_categories(data)
        tags = sanitize_line(data.get("tags", ""))
        owner = sanitize_line(data.get("owner", "")) or "Wiki-Verantwortlicher"
        summary = sanitize_line(data.get("summary", ""))
        changed_by = sanitize_line(data.get("changedBy", "System"))
        body = str(data.get("body") or "") or f"# {title}\n\n"
        prods = data.get("products", [])
        prod_val = ", ".join(split_list(prods) if isinstance(prods, str) else
                             [sanitize_line(x) for x in (prods or []) if sanitize_line(x)])
        atts = data.get("attachments", [])
        att_val = "; ".join(f"{sanitize_line(a.get('path', ''))}|{sanitize_line(a.get('name', ''))}"
                            if isinstance(a, dict) else sanitize_line(a) for a in (atts or []))
        related = []
        for r in data.get("related", []) or []:
            s = slugify(str(r))
            if s and s != slug and s not in related:
                related.append(s)
        reason_v = sanitize_line(reason) or "Erstellt"
        dr = data.get("deleteRequest") if isinstance(data.get("deleteRequest"), dict) else None
        b, a, rr = "", "", ""
        if dr:
            b, a, rr = sanitize_line(dr.get("by", "")), sanitize_line(dr.get("at", "")), sanitize_line(dr.get("reason", ""))
        body_log = self.add_revision_entry(body, existing_log, revision, action, reason_v, changed_by or "System")
        date = now_local().strftime("%Y-%m-%d")
        dt = now_local().strftime("%Y-%m-%d %H:%M")
        return "\n".join(["---", f"title: {title}", f"slug: {slug}",
                           f"category: {cats[0]}", f"categories: {', '.join(cats)}",
                           f"tags: {tags}", f"owner: {owner}", "status: Entwurf",
                           f"updated: {date}", f"summary: {summary}",
                           f"products: {prod_val}", f"attachments: {att_val}",
                           f"revision: {revision}", f"change_date: {dt}",
                           f"change_action: {action}", f"change_reason: {reason_v}",
                           f"changed_by: {changed_by or 'System'}",
                           f"related: {', '.join(related)}",
                           f"delete_request_by: {b}", f"delete_request_at: {a}",
                           f"delete_request_reason: {rr}", "---", "",
                           body_log.strip(), ""])

    # ----- build / wiki-data -----
    def build_payload(self):
        products = [p for p in self.read_products() if p["name"] and p["article"]]
        archived_products = [p for p in self.read_archived_products() if p["name"] and p["article"]]
        cat_entries = self.read_categories()
        configured = []
        cat_products = {}
        for c in cat_entries:
            if c["name"] and c["name"] not in configured:
                configured.append(c["name"])
            cat_products[c["name"]] = list(c["products"])
        groups = self.read_category_groups()
        # Artikel einlesen
        raws = []
        slug_lookup = {}
        files = sorted(self.articles_dir.glob("*.md")) if self.articles_dir.exists() else []
        for f in files:
            raw = f.read_text(encoding="utf-8-sig")
            meta, body = self.parse_frontmatter(raw)
            title = meta.get("title", f.stem)
            slug = slugify(meta.get("slug", title))
            if slug in slug_lookup:
                raise WikiError(400, f"Duplicate slug '{slug}' in {f}")
            slug_lookup[slug] = True
            rel = f.relative_to(self.root).as_posix()
            raws.append({"source": f.name, "sourcePath": rel, "archived": False,
                         "slug": slug, "title": title, "meta": meta, "body": body})
        if self.archive_dir.exists():
            for f in sorted(self.archive_dir.rglob("*.md")):
                raw = f.read_text(encoding="utf-8-sig")
                meta, body = self.parse_frontmatter(raw)
                title = meta.get("title", f.stem)
                slug = slugify(meta.get("slug", title))
                if slug in slug_lookup:
                    slug = slug + "-archiv"
                    if slug in slug_lookup:
                        continue
                slug_lookup[slug] = True
                rel = f.relative_to(self.root).as_posix()
                raws.append({"source": f.name, "sourcePath": rel, "archived": True,
                             "slug": slug, "title": title, "meta": meta, "body": body})
        articles = []
        for a in raws:
            meta = a["meta"]
            cats = self.article_categories(None, meta)
            rev = self.revision_of(meta)
            prods = split_list(meta.get("products", ""))
            if not prods:
                fb = []
                for c in cats:
                    fb.extend(cat_products.get(c, []))
                prods = sorted(set(x for x in fb if x))
            atts = []
            if meta.get("attachments", "").strip():
                for entry in str(meta["attachments"]).split(";"):
                    entry = entry.strip()
                    if entry:
                        parts = entry.split("|", 1)
                        p = parts[0].strip()
                        n = parts[1].strip() if len(parts) > 1 else os.path.basename(p)
                        if p:
                            atts.append({"path": p, "name": n})
            plain = re.sub(r"[#*_`\[\]\(\)>-]", " ", a["body"])
            plain = re.sub(r"data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+", "[Bild]", plain)
            html_body = markdown_to_html(a["body"], slug_lookup)
            edit_body = self.remove_revision_log(a["body"])
            dr = None
            if meta.get("delete_request_by", "").strip():
                dr = {"by": meta.get("delete_request_by", ""),
                      "at": meta.get("delete_request_at", ""),
                      "reason": meta.get("delete_request_reason", "")}
            articles.append({
                "slug": a["slug"], "title": a["title"],
                "category": "Archiv" if a["archived"] else cats[0],
                "categories": ["Archiv"] if a["archived"] else cats,
                "tags": split_list(meta.get("tags", "")),
                "owner": meta.get("owner", ""),
                "status": "Archiviert" if a["archived"] else meta.get("status", "Entwurf"),
                "updated": meta.get("updated", ""),
                "summary": meta.get("summary", ""),
                "revision": rev,
                "changeDate": meta.get("change_date", ""),
                "changeReason": meta.get("change_reason", ""),
                "changeAction": meta.get("change_action", ""),
                "changedBy": meta.get("changed_by", ""),
                "archived": a["archived"],
                "products": prods, "attachments": atts,
                "related": related_slugs(meta.get("related", "")),
                "deleteRequest": dr, "source": a["source"],
                "sourcePath": a["sourcePath"], "editBody": edit_body,
                "html": html_body, "searchText": plain,
            })
        # Gegenverknuepfungen auch fuer Altdaten sichtbar machen: Ein Link in
        # einem aktiven Artikel erzeugt automatisch den Ruecklink. Die Dateien
        # werden erst beim naechsten Speichern persistiert.
        active_related = {a["slug"]: set(a["related"]) for a in articles
                          if not a["archived"]}
        reverse_related = {}
        for source_slug, links in active_related.items():
            for target_slug in links:
                if target_slug and target_slug != source_slug:
                    reverse_related.setdefault(target_slug, set()).add(source_slug)
        for a in articles:
            if a["archived"]:
                continue
            merged = list(a["related"])
            for source_slug in sorted(reverse_related.get(a["slug"], set())):
                if source_slug not in merged:
                    merged.append(source_slug)
            a["related"] = merged
        all_cats = list(configured)
        for a in articles:
            for c in a["categories"]:
                if c and c not in all_cats:
                    all_cats.append(c)
        if any(a["archived"] for a in articles) and "Archiv" not in all_cats:
            all_cats.append("Archiv")
        grouped = {c for g in groups for c in g["categories"]}
        ungrouped = [c for c in all_cats if c not in grouped]
        if ungrouped:
            groups = list(groups) + [{"name": "Weitere Kategorien", "categories": ungrouped}]
        # Stabile Gruppenreihenfolge (Alle implizit zuerst, Archiv zuletzt).
        _order = ["Alarmtechnik", "Videotechnik", "Zutrittskontrolle", "Wiki", "Technik"]

        def _gkey(g):
            n = g.get("name", "")
            if n == "Archiv":
                return (999, n)
            if n in _order:
                return (_order.index(n), n)
            if n == "Weitere Kategorien":
                return (50, n)
            return (40, n)

        groups = sorted(groups, key=_gkey)
        # generatedAt = neueste Content-Datei
        newest = None
        for f in self.root.joinpath("content").rglob("*"):
            if f.is_file() and "conflicts" not in f.parts:
                try:
                    mt = f.stat().st_mtime
                    newest = max(newest or 0, mt)
                except Exception:
                    pass
        gen = (datetime.fromtimestamp(newest, tz=timezone.utc).astimezone().isoformat()
               if newest else iso_now())
        payload = {"generatedAt": gen, "articleCount": len(articles),
                   "categories": all_cats, "categoryGroups": groups,
                   "categoryProducts": cat_products, "products": products,
                   "archivedProducts": archived_products, "articles": articles}
        # Cache-Datei schreiben (Export/Offline)
        try:
            atomic_write_text(self.data_file,
                              "window.WIKI_DATA = " + json.dumps(payload, ensure_ascii=False) + ";")
        except Exception:
            pass
        return payload

    def system_status(self):
        conflicts = {"conflicts": [], "duplicateSlugs": []}
        try:
            rp = self.root / "content" / "conflicts" / "report.json"
            if rp.exists():
                conflicts = json.loads(rp.read_text(encoding="utf-8-sig"))
        except Exception:
            pass
        return {"buildError": "", "conflicts": conflicts}

    # ----- snapshot (Linux: git + zip, nie blockierend) -----
    def snapshot(self, message):
        try:
            with self.lock:
                self.versions_dir.mkdir(parents=True, exist_ok=True)
            stamp = now_local().strftime("%Y%m%d-%H%M%S")
            safe = re.sub(r"[^A-Za-z0-9._-]+", "_", message or "snapshot")[:60]
            # git commit wenn repo vorhanden
            try:
                subprocess.run(["git", "-C", str(self.root), "add", "-A"],
                               timeout=20, capture_output=True)
                subprocess.run(["git", "-C", str(self.root), "commit", "-m",
                                f"{stamp} {message}"], timeout=20, capture_output=True)
            except Exception:
                pass
        except Exception as e:
            try:
                with open(self.versions_dir / "snapshot-errors.log", "a", encoding="utf-8") as fh:
                    fh.write(f"{iso_now()} {message}: {e}\n")
            except Exception:
                pass

    # ----- backup (nur Administratoren) -----
    def assert_backup_admin(self, session):
        if session is None:
            raise AuthError()
        role = session.get("role", "")
        perms = self.role_perms(role)
        if role != "Administrator" and not ("users.manage" in perms and "roles.manage" in perms):
            raise AuthError("Nur Administratoren duerfen Backups verwalten.")

    def create_backup(self, data, session):
        self.assert_backup_admin(session)
        stamp = now_local().strftime("%Y%m%d-%H%M%S")
        fname = f"wiki-backup-{stamp}.zip"
        dest_zip = self.backup_dir / fname
        tmp = Path(tempfile.mkdtemp(prefix="wiki-backup-"))
        try:
            (tmp / "manifest.json").write_text(json.dumps({
                "backupVersion": 1, "createdAt": iso_now(),
                "applicationVersion": "wiki-2026-10",
                "createdBy": session.get("username", "")}, ensure_ascii=False), encoding="utf-8")
            for rel in ("content/articles", "content/archive", "content/uploads"):
                src = self.root / rel
                if src.is_dir():
                    shutil.copytree(src, tmp / rel, dirs_exist_ok=True)
            for rel in ("content/categories.json", "content/category-groups.json",
                        "content/products.json", "content/product-archive.json",
                        "data/wiki-data.js", "config/roles.json"):
                src = self.root / rel
                if src.is_file():
                    dst = tmp / rel
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
            (tmp / "HINWEIS-Benutzer.txt").write_text(
                "Benutzerkonten (config/users.json) sind aus Sicherheitsgruenden "
                "nicht enthalten. Rollen in config/roles.json.", encoding="utf-8")
            with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED) as zf:
                for f in sorted(tmp.rglob("*")):
                    if f.is_file():
                        zf.write(f, f.relative_to(tmp).as_posix())
            article_count = len(list(self.articles_dir.glob("*.md"))) if self.articles_dir.exists() else 0
            image_count = sum(1 for f in self.uploads_dir.rglob("*") if f.is_file()) if self.uploads_dir.exists() else 0
            note = ""
            target = sanitize_line((data or {}).get("targetPath", ""))
            if target:
                try:
                    full = Path(target).resolve()
                    full.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(dest_zip, full / fname)
                    note += f" Kopie nach {full}."
                except Exception as e:
                    note += f" Zielpfad nicht erreichbar (Server-Sicht): {e}"
            wurl = str((data or {}).get("webdavUrl", "") or "").strip()
            wuser = str((data or {}).get("webdavUser", "") or "").strip()
            wpass = str((data or {}).get("webdavPassword", "") or "")
            if wurl:
                try:
                    if not re.match(r"^https?://", wurl):
                        raise WikiError(400, "WebDAV-URL muss mit http(s):// beginnen.")
                    req = urllib.request.Request(wurl.rstrip("/") + "/" + fname,
                                                 data=dest_zip.read_bytes(), method="PUT")
                    if wuser:
                        token = base64.b64encode(f"{wuser}:{wpass}".encode("utf-8")).decode()
                        req.add_header("Authorization", "Basic " + token)
                    urllib.request.urlopen(req, timeout=120).close()
                    note += " WebDAV-Upload ok."
                except Exception:
                    note += " WebDAV fehlgeschlagen (Details serverseitig protokolliert, ohne Passwort)."
            if note:
                try:
                    with open(self.versions_dir / "snapshot-errors.log", "a", encoding="utf-8") as fh:
                        fh.write(f"{iso_now()} Backup {fname}:{note}\n")
                except Exception:
                    pass
            return {"ok": True, "fileName": fname, "articleCount": article_count,
                    "imageCount": image_count,
                    "downloadUrl": f"/api/backup/download/{fname}", "note": note.strip()}
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def restore_backup(self, data, session):
        self.assert_backup_admin(session)
        fname = sanitize_filename(str((data or {}).get("fileName", "")))
        b64 = str((data or {}).get("data", "") or "")
        if not b64.strip():
            raise WikiError(400, "Backup-Datei fehlt.")
        try:
            raw = base64.b64decode(re.sub(r"\s+", "", b64))
        except Exception:
            raise WikiError(400, "Backup-Datei ist beschaedigt (kein gueltiges Base64).")
        if not raw or len(raw) > 500 * 1024 * 1024:
            raise WikiError(400, "Backup-Datei ist ungueltig oder zu gross.")
        tmp_zip = Path(tempfile.gettempdir()) / f"restore-{secrets.token_hex(8)}.zip"
        tmp_dir = Path(tempfile.gettempdir()) / f"restore-{secrets.token_hex(8)}"
        tmp_zip.write_bytes(raw)
        try:
            tmp_dir.mkdir(parents=True, exist_ok=True)
            try:
                with zipfile.ZipFile(tmp_zip) as zf:
                    # Zip-Slip-Schutz: keine absoluten Pfade / Ausbrueche.
                    base = tmp_dir.resolve()
                    for m in zf.namelist():
                        dest = (base / m).resolve()
                        try:
                            dest.relative_to(base)
                        except Exception:
                            raise WikiError(400, "Backup enthaelt ungueltige Pfade.")
                    zf.extractall(tmp_dir)
            except WikiError:
                raise
            except Exception:
                raise WikiError(400, "Backup ist beschaedigt (kein gueltiges ZIP).")
            mf = tmp_dir / "manifest.json"
            if not mf.is_file():
                raise WikiError(400, "Backup ungueltig: manifest.json fehlt.")
            try:
                manifest = json.loads(mf.read_text(encoding="utf-8-sig"))
            except Exception:
                raise WikiError(400, "Backup ungueltig: manifest.json defekt.")
            if int(manifest.get("backupVersion", 0)) != 1:
                raise WikiError(400, f"Backup-Version {manifest.get('backupVersion')} wird nicht unterstuetzt (erwartet 1).")
            for rel in ("content/articles", "content/categories.json", "content/products.json"):
                if not (tmp_dir / rel).exists():
                    raise WikiError(400, f"Backup unvollstaendig: {rel} fehlt.")
            if not list((tmp_dir / "content" / "articles").glob("*.md")):
                raise WikiError(400, "Backup unvollstaendig: keine Artikel-Dateien enthalten. Restore abgebrochen, Daten unveraendert.")
            for rel in ("content/categories.json", "content/category-groups.json",
                        "content/products.json", "content/product-archive.json"):
                p = tmp_dir / rel
                if p.is_file():
                    try:
                        json.loads(p.read_text(encoding="utf-8-sig"))
                    except Exception:
                        raise WikiError(400, f"Backup beschaedigt: {rel} ist kein gueltiges JSON.")
            pre = self.backup_dir / f"pre-restore-{now_local().strftime('%Y%m%d-%H%M%S')}.zip"
            try:
                with zipfile.ZipFile(pre, "w", zipfile.ZIP_DEFLATED) as zf:
                    for src in (self.root / "content", self.roles_file):
                        if src.is_dir():
                            for f in src.rglob("*"):
                                if f.is_file():
                                    zf.write(f, f.relative_to(self.root).as_posix())
                        elif src.is_file():
                            zf.write(src, src.relative_to(self.root).as_posix())
            except Exception:
                pass
            for rel in ("content/articles", "content/archive", "content/uploads"):
                src, dst = tmp_dir / rel, self.root / rel
                if src.is_dir():
                    if rel != "content/uploads" and not any(src.rglob("*")) and dst.is_dir():
                        continue
                    dst.mkdir(parents=True, exist_ok=True)
                    for f in dst.glob("*"):
                        if f.is_dir():
                            shutil.rmtree(f, ignore_errors=True)
                        else:
                            f.unlink(missing_ok=True)
                    for f in src.glob("*"):
                        if f.is_dir():
                            shutil.copytree(f, dst / f.name, dirs_exist_ok=True)
                        else:
                            shutil.copy2(f, dst / f.name)
            for rel in ("content/categories.json", "content/category-groups.json",
                        "content/products.json", "content/product-archive.json"):
                src = tmp_dir / rel
                if src.is_file():
                    shutil.copy2(src, self.root / rel)
            payload = self.build_payload()
            payload["systemStatus"] = self.system_status()
            self.snapshot(f"Backup wiederhergestellt: {fname} durch {session.get('username', '')}")
            payload["restoredArticles"] = len(list(self.articles_dir.glob("*.md"))) if self.articles_dir.exists() else 0
            payload["restoredImages"] = sum(1 for f in self.uploads_dir.rglob("*") if f.is_file()) if self.uploads_dir.exists() else 0
            return payload
        finally:
            try:
                tmp_zip.unlink(missing_ok=True)
            except Exception:
                pass
            shutil.rmtree(tmp_dir, ignore_errors=True)

    # ----- suggestions -----
    # Statusmodell: open (Warten auf Freigabe) -> accepted/rejected (Bearbeitet,
    # wartet auf Abschluss durch Ersteller) -> per Acknowledge geloescht (kein Archiv).
    def migrate_suggestions(self):
        if not self.suggestions_dir.exists():
            return
        for f in self.suggestions_dir.glob("*.json"):
            try:
                item = json.loads(f.read_text(encoding="utf-8-sig"))
                changed = False
                for field in ("kind", "type", "status", "productId", "title",
                              "body", "note", "author", "authorDisplay",
                              "createdAt", "rejectionReason", "rejectedAt", "rejectedBy",
                              "processedAt", "processedBy", "decision"):
                    if field not in item:
                        item[field] = ""
                        changed = True
                if not item.get("kind"):
                    item["kind"] = "article"
                    changed = True
                if not item.get("type"):
                    item["type"] = "change"
                    changed = True
                if not item.get("status"):
                    item["status"] = "open"
                    changed = True
                if item.get("status") == "rejected" and not item.get("decision"):
                    item["decision"] = "rejected"
                    changed = True
                if changed:
                    atomic_write_json(f, item)
            except Exception:
                pass

    def read_suggestions(self):
        items = []
        if not self.suggestions_dir.exists():
            return items
        for f in self.suggestions_dir.glob("*.json"):
            try:
                item = json.loads(f.read_text(encoding="utf-8-sig"))
                items.append({
                    "id": f.stem,
                    "kind": item.get("kind") or "article",
                    "type": item.get("type") or "change",
                    "status": item.get("status") or "open",
                    "slug": str(item.get("slug", "")),
                    "productId": str(item.get("productId", "")),
                    "title": str(item.get("title", "")),
                    "body": str(item.get("body", "")),
                    "note": str(item.get("note", "")),
                    "fields": item.get("fields"),
                    "author": str(item.get("author", "")),
                    "authorDisplay": str(item.get("authorDisplay", item.get("author", ""))),
                    "createdAt": str(item.get("createdAt", "")),
                    "rejectionReason": str(item.get("rejectionReason", "")),
                    "rejectedAt": str(item.get("rejectedAt", "")),
                    "rejectedBy": str(item.get("rejectedBy", "")),
                    "processedAt": str(item.get("processedAt", "")),
                    "processedBy": str(item.get("processedBy", "")),
                    "decision": str(item.get("decision", "")),
                })
            except Exception:
                continue
        return sorted(items, key=lambda x: x["createdAt"], reverse=True)


STORE = None


# ---------- HTTP ----------
class Handler(BaseHTTPRequestHandler):
    server_version = "WikiLinux/1.0"

    def log_message(self, fmt, *args):
        pass

    def _send_json(self, status, obj, cookie=None):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        if cookie is not None:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status, message):
        self._send_json(status, {"error": message})

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        if not raw.strip():
            return {}
        try:
            v = json.loads(raw.decode("utf-8"))
            return v if isinstance(v, dict) else {}
        except Exception as e:
            raise WikiError(400, f"Ungueltiges JSON: {e}")

    def _cookie(self, name):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                if k == name:
                    return urllib.parse.unquote(v)
        return ""

    def _session(self):
        return STORE.session_from_token(self._cookie("wiki_session"))

    def _serve_file(self, url_path):
        p = urllib.parse.unquote(url_path.lstrip("/"))
        if not p:
            p = "index.html"
        norm = p.replace("\\", "/")
        ok = (norm == "index.html" or norm.startswith("assets/")
              or norm.startswith("content/uploads/")
              or norm.startswith("Anhaenge/") or norm.startswith("Anhänge/"))
        if not ok:
            self._send_error(404, "Datei nicht gefunden.")
            return
        full = (STORE.root / p).resolve()
        try:
            full.relative_to(STORE.root.resolve())
        except Exception:
            self._send_error(404, "Datei nicht gefunden.")
            return
        if not full.is_file():
            self._send_error(404, "Datei nicht gefunden.")
            return
        ext = full.suffix.lower()
        ctype = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
                 ".js": "application/javascript; charset=utf-8",
                 ".json": "application/json; charset=utf-8",
                 ".md": "text/markdown; charset=utf-8", ".png": "image/png",
                 ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
                 ".webp": "image/webp", ".svg": "image/svg+xml",
                 ".pdf": "application/pdf",
                 ".doc": "application/msword",
                 ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                 ".xls": "application/vnd.ms-excel",
                 ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                 ".ppt": "application/vnd.ms-powerpoint",
                 ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
                 ".txt": "text/plain; charset=utf-8",
                 ".csv": "text/csv; charset=utf-8",
                 ".zip": "application/zip"}.get(ext, "application/octet-stream")
        data = full.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache" if ext in (".html", ".js", ".css")
                         else "public, max-age=3600")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def _send_download(self, full: Path, name: str):
        data = full.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.route()

    def do_POST(self):
        self.route()

    def do_PUT(self):
        self.route()

    def do_DELETE(self):
        self.route()

    def route(self):
        try:
            path = urllib.parse.urlparse(self.path).path
            method = self.command
            if method == "OPTIONS":
                return self.do_OPTIONS()
            # oeffentlich
            if path == "/api/status" and method == "GET":
                users = STORE.read_users()
                sess = self._session()
                perms = STORE.role_perms(sess["role"]) if sess else []
                self._send_json(200, {
                    "editor": True, "root": str(STORE.root),
                    "setupRequired": len(users) == 0,
                    "authenticated": sess is not None,
                    "user": ({"username": sess["username"],
                              "displayName": sess["displayName"],
                              "role": sess["role"]} if sess else None),
                    "permissions": perms,
                    "locks": STORE.public_locks() if sess else []})
                return
            if path == "/api/auth/setup" and method == "POST":
                users = STORE.read_users()
                if users:
                    raise WikiError(409, "Die Ersteinrichtung wurde bereits abgeschlossen.")
                data = self._read_json()
                username = sanitize_line(data.get("username", ""))
                password = str(data.get("password", ""))
                if not USERNAME_RE.match(username.lower()):
                    raise WikiError(400, "Der Benutzername muss 3 bis 40 Zeichen lang sein und darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten.")
                if "Administrator" not in STORE.read_roles():
                    raise WikiError(400, "Unbekannte Benutzerrolle.")
                pw = STORE.hash_password(password)
                admin = {"username": username.lower(), "displayName": username,
                         "role": "Administrator", "passwordHash": pw["hash"],
                         "salt": pw["salt"], "iterations": pw["iterations"],
                         "algorithm": pw["algorithm"], "active": True,
                         "createdAt": iso_now()}
                STORE.write_users([admin])
                sess = STORE.new_session(admin)
                self._send_json(200, {"user": {k: admin[k] for k in
                    ("username", "displayName", "role", "active")}},
                    cookie=f"wiki_session={sess['token']}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")
                return
            if path == "/api/auth/login" and method == "POST":
                data = self._read_json()
                username = sanitize_line(data.get("username", "")).lower()
                user = next((u for u in STORE.read_users()
                             if u.get("username") == username and u.get("active")), None)
                if not user or not STORE.check_password(str(data.get("password", "")), user):
                    raise WikiError(401, "Benutzername oder Passwort ist falsch.")
                sess = STORE.new_session(user)
                self._send_json(200, {"user": {k: user[k] for k in
                    ("username", "displayName", "role", "active")}},
                    cookie=f"wiki_session={sess['token']}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")
                return
            if path == "/api/auth/logout" and method == "POST":
                sess = self._session()
                if sess:
                    STORE.release_user_locks(sess["username"])
                    STORE.sessions.pop(sess["token"], None)
                self._send_json(200, {"ok": True},
                    cookie="wiki_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0")
                return
            sess = self._session()
            if sess is None:
                if method == "GET" and (path in ("/", "/index.html") or path.startswith("/assets/")):
                    return self._serve_file(path)
                raise WikiError(401, "Bitte zuerst anmelden.")
            # ---- account ----
            if path == "/api/account" and method == "GET":
                own = next((u for u in STORE.read_users() if u["username"] == sess["username"]), None)
                if not own:
                    raise WikiError(404, "Benutzer nicht gefunden.")
                self._send_json(200, {k: own[k] for k in ("username", "displayName", "role", "active")})
                return
            if path == "/api/account" and method == "PUT":
                users = STORE.read_users()
                own = next((u for u in users if u["username"] == sess["username"]), None)
                if not own:
                    raise WikiError(404, "Benutzer nicht gefunden.")
                if not own.get("active"):
                    raise AuthError("Das Konto ist deaktiviert.")
                data = self._read_json()
                changed = False
                if "displayName" in data:
                    nd = sanitize_line(data.get("displayName", ""))
                    if not nd or len(nd) > 80:
                        raise WikiError(400, "Der Anzeigename muss 1 bis 80 Zeichen lang sein.")
                    if nd != own.get("displayName"):
                        own["displayName"] = nd
                        sess["displayName"] = nd
                        changed = True
                if data.get("newPassword"):
                    if not STORE.check_password(str(data.get("currentPassword", "")), own):
                        raise WikiError(403, "Das aktuelle Passwort ist falsch.")
                    pw = STORE.hash_password(str(data["newPassword"]))
                    own.update(passwordHash=pw["hash"], salt=pw["salt"],
                               iterations=pw["iterations"])
                    changed = True
                if changed:
                    STORE.write_users(users)
                self._send_json(200, {k: own[k] for k in ("username", "displayName", "role", "active")})
                return
            # ---- wiki-data ----
            if path == "/api/wiki-data" and method == "GET":
                STORE.assert_perm(sess, ["articles.view"])
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                if not any(p.startswith("products.") for p in STORE.role_perms(sess["role"])):
                    payload = dict(payload)
                    payload["products"] = []
                    payload["archivedProducts"] = []
                    payload["categoryProducts"] = {}
                self._send_json(200, payload)
                return
            if path == "/api/roles" and method == "GET":
                STORE.assert_perm(sess, ["roles.manage"])
                self._send_json(200, {"roles": STORE.read_roles(), "permissions": ALL_PERMISSIONS})
                return
            if path == "/api/roles" and method == "PUT":
                STORE.assert_perm(sess, ["roles.manage"])
                data = self._read_json()
                roles = data.get("roles")
                if not isinstance(roles, dict):
                    raise WikiError(400, "Rollen fehlen.")
                clean = {}
                for name, perms in roles.items():
                    rn = sanitize_line(name)
                    if not ROLENAME_RE.match(rn):
                        raise WikiError(400, f"Ungueltiger Rollenname: {name}")
                    perms = perms if isinstance(perms, list) else []
                    unknown = [p for p in perms if p not in ALL_PERMISSIONS]
                    if unknown:
                        raise WikiError(400, f"Unbekannte Berechtigungen: {', '.join(unknown)}")
                    clean[rn] = sorted(set(perms))
                if not clean or not any("roles.manage" in v and "users.manage" in v for v in clean.values()):
                    raise WikiError(400, "Mindestens eine Rolle muss Benutzer- und Rollenverwaltung behalten.")
                STORE.write_roles(clean)
                STORE.snapshot(f"Rollen aktualisiert durch {sess['username']}")
                self._send_json(200, {"roles": STORE.read_roles(), "permissions": ALL_PERMISSIONS})
                return
            if path == "/api/users" and method == "GET":
                STORE.assert_perm(sess, ["users.manage"])
                self._send_json(200, [{k: u[k] for k in ("username", "displayName", "role", "active")}
                                      for u in STORE.read_users()])
                return
            if path == "/api/users" and method == "POST":
                STORE.assert_perm(sess, ["users.manage"])
                data = self._read_json()
                users = STORE.read_users()
                username = sanitize_line(data.get("username", ""))
                if not USERNAME_RE.match(username.lower()):
                    raise WikiError(400, "Der Benutzername muss 3 bis 40 Zeichen lang sein und darf nur Buchstaben, Zahlen, Punkt, Unterstrich und Bindestrich enthalten.")
                if sanitize_line(data.get("role", "")) not in STORE.read_roles():
                    raise WikiError(400, "Unbekannte Benutzerrolle.")
                if any(u["username"] == username.lower() for u in users):
                    raise WikiError(409, "Der Benutzername ist bereits vergeben.")
                pw = STORE.hash_password(str(data.get("password", "")))
                users.append({"username": username.lower(), "displayName": username,
                              "role": sanitize_line(data.get("role", "")),
                              "passwordHash": pw["hash"], "salt": pw["salt"],
                              "iterations": pw["iterations"], "algorithm": pw["algorithm"],
                              "active": True, "createdAt": iso_now()})
                STORE.write_users(users)
                STORE.snapshot(f"Benutzer angelegt: {username.lower()}")
                self._send_json(200, [{k: u[k] for k in ("username", "displayName", "role", "active")}
                                      for u in STORE.read_users()])
                return
            m = re.match(r"^/api/users/([^/]+)$", path)
            if m and method == "PUT":
                STORE.assert_perm(sess, ["users.manage"])
                users = STORE.read_users()
                target = next((u for u in users
                               if u["username"] == urllib.parse.unquote(m.group(1)).lower()), None)
                if not target:
                    raise WikiError(404, "Benutzer nicht gefunden.")
                data = self._read_json()
                if "role" in data:
                    nr = sanitize_line(data.get("role", ""))
                    if nr not in STORE.read_roles():
                        raise WikiError(400, "Unbekannte Benutzerrolle.")
                    target["role"] = nr
                if "displayName" in data:
                    nd = sanitize_line(data.get("displayName", ""))
                    if not nd or len(nd) > 80:
                        raise WikiError(400, "Der Anzeigename muss 1 bis 80 Zeichen lang sein.")
                    target["displayName"] = nd
                if "active" in data:
                    target["active"] = bool(data["active"])
                if data.get("password"):
                    pw = STORE.hash_password(str(data["password"]))
                    target.update(passwordHash=pw["hash"], salt=pw["salt"],
                                   iterations=pw["iterations"])
                if target["username"] == sess["username"]:
                    perms = STORE.role_perms(target["role"])
                    if (not target["active"] or "users.manage" not in perms
                            or "roles.manage" not in perms):
                        raise WikiError(400, "Das eigene Konto darf nicht von Benutzer-/Rollenverwaltung ausgeschlossen oder deaktiviert werden.")
                STORE.write_users(users)
                self._send_json(200, [{k: u[k] for k in ("username", "displayName", "role", "active")}
                                      for u in STORE.read_users()])
                return
            if path == "/api/locks" and method == "GET":
                self._send_json(200, STORE.public_locks())
                return
            m = re.match(r"^/api/locks/(.+)$", path)
            if m:
                slug = urllib.parse.unquote(m.group(1))
                if method == "POST":
                    self._send_json(200, STORE.acquire_lock(slug, sess))
                    return
                if method == "DELETE":
                    STORE.release_lock(slug, sess)
                    self._send_json(200, {"ok": True})
                    return
            if path == "/api/categories" and method == "POST":
                # Produktgruppe unabhaengig anlegen: Produkte und Gruppe optional,
                # ohne Gruppe bleibt sie unzugeordnet (kein Auto-Assign).
                STORE.assert_cat_assign(sess)
                data = self._read_json()
                name = sanitize_line(data.get("name", ""))
                if not name or name == "Archiv":
                    raise WikiError(400, "Ungueltige Kategorie.")
                prods = data.get("products", data.get("productIds", []))
                prods = prods if isinstance(prods, list) else split_list(prods)
                prods = [sanitize_line(x) for x in prods if sanitize_line(x)]
                if prods:
                    known = {p["id"] for p in STORE.read_products()}
                    for pid in prods:
                        if pid not in known:
                            raise WikiError(400, f"Unbekanntes Produkt: {pid}")
                cats = STORE.read_categories()
                group = sanitize_line(data.get("group", ""))
                entry = next((c for c in cats if c["name"] == name), None)
                if entry:
                    if prods:
                        entry["products"] = sorted(set(entry["products"]) | set(prods))
                else:
                    cats.append({"name": name, "products": prods})
                STORE.write_categories(cats)
                if group:
                    if group == "Archiv":
                        raise WikiError(400, "Die systemseitige Kategorie Archiv kann nicht zugeordnet werden.")
                    groups = STORE.read_category_groups()
                    g = next((x for x in groups if x["name"] == group), None)
                    if g:
                        if name not in g["categories"]:
                            g["categories"].append(name)
                    else:
                        groups.append({"name": group, "categories": [name]})
                    STORE.write_category_groups(groups)
                STORE.snapshot(f"Kategorien aktualisiert durch {sess['username']}")
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            if path == "/api/category-groups" and method == "POST":
                # Neue Ueberkategorie -> manage; bestehende Zuordnung -> assign.
                # "Weitere Kategorien" ist Anzeige-Bucket und wird nie echt.
                data = self._read_json()
                name = sanitize_line(data.get("name", ""))
                if not name or name == "Archiv":
                    raise WikiError(400, "Ungueltige Gruppe.")
                if name == "Weitere Kategorien":
                    raise WikiError(400, 'Der Name "Weitere Kategorien" ist ein Anzeigeordner und kann nicht als Ueberkategorie angelegt werden.')
                groups = STORE.read_category_groups()
                if not any(x["name"] == name for x in groups):
                    STORE.assert_perm(sess, ["categories.manage"])
                else:
                    STORE.assert_cat_assign(sess)
                cats = data.get("categories", []) or []
                cats = [normalize_category(c) for c in (cats if isinstance(cats, list) else [cats])]
                cats = [c for c in cats if c and c != "Archiv"]
                new_cats = data.get("newCategories", []) or []
                products = STORE.read_products()
                known_p = {p["id"] for p in products}
                all_cats = STORE.read_categories()
                for nc in new_cats:
                    if isinstance(nc, dict):
                        nn = normalize_category(nc.get("name", ""))
                        nps = nc.get("products", nc.get("productIds", [])) or []
                        nps = [sanitize_line(x) for x in (nps if isinstance(nps, list) else [nps]) if sanitize_line(x)]
                    else:
                        nn, nps = normalize_category(nc), []
                    if not nn or nn == "Archiv" or nn in cats:
                        continue
                    for pid in nps:
                        if pid not in known_p:
                            raise WikiError(400, f"Unbekanntes Produkt: {pid}")
                    if not any(c["name"] == nn for c in all_cats):
                        all_cats.append({"name": nn, "products": nps})
                    if nn not in cats:
                        cats.append(nn)
                STORE.write_categories(all_cats)
                groups = STORE.read_category_groups()
                g = next((x for x in groups if x["name"] == name), None)
                if g:
                    g["categories"] = cats
                else:
                    groups.append({"name": name, "categories": cats})
                STORE.write_category_groups(groups)
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/categories/([^/]+)$", path)
            if m and method == "DELETE":
                STORE.assert_perm(sess, ["categories.manage"])
                name = sanitize_line(urllib.parse.unquote(m.group(1)))
                if not name or name == "Archiv":
                    raise WikiError(400, "Ungueltige Kategorie.")
                cats = STORE.read_categories()
                if not any(c["name"] == name for c in cats):
                    raise WikiError(404, "Kategorie nicht gefunden.")
                used_articles, used_products = STORE.category_usage(name)
                if used_articles or used_products:
                    parts = []
                    if used_articles:
                        parts.append(f"{len(used_articles)} Artikel ({', '.join(used_articles[:3])})")
                    if used_products:
                        parts.append(f"{len(used_products)} Produkte ({', '.join(used_products[:3])})")
                    raise WikiError(409, "Kategorie wird noch verwendet und kann nicht geloescht werden: "
                                        + "; ".join(parts) + ". Bitte zuerst die Zuordnungen entfernen.")
                groups = STORE.read_category_groups()
                for g in groups:
                    g["categories"] = [c for c in g["categories"] if c != name]
                STORE.write_category_groups(groups)
                STORE.write_categories([c for c in cats if c["name"] != name])
                STORE.snapshot(f"Produktgruppe geloescht durch {sess['username']}: {name}")
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/category-groups/([^/]+)$", path)
            if m and method == "DELETE":
                STORE.assert_perm(sess, ["categories.manage"])
                name = sanitize_line(urllib.parse.unquote(m.group(1)))
                if not name or name in ("Archiv", "Weitere Kategorien"):
                    raise WikiError(400, "Ungueltige Ueberkategorie.")
                groups = STORE.read_category_groups()
                if not any(x["name"] == name for x in groups):
                    raise WikiError(404, "Ueberkategorie nicht gefunden.")
                STORE.write_category_groups([x for x in groups if x["name"] != name])
                STORE.snapshot(f"Ueberkategorie geloescht durch {sess['username']}: {name}")
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            if path == "/api/products" and method == "POST":
                STORE.assert_perm(sess, ["products.create"])
                data = self._read_json()
                name = sanitize_line(data.get("name", ""))
                article = sanitize_line(data.get("article", data.get("artikel", "")))
                if not name:
                    raise WikiError(400, "Produktname fehlt.")
                if not article:
                    raise WikiError(400, "Artikel ist ein Pflichtfeld.")
                products = STORE.read_products()
                hw = sanitize_line(data.get("hardwareRevision", data.get("hardwarerevision", "")))
                pid = slugify(f"{name}-{article}-{hw}")
                if any(p["id"] == pid for p in products):
                    raise WikiError(409, "Dieses Produkt existiert bereits.")
                pcats = data.get("categories", data.get("categoryIds", [])) or []
                pcats = [normalize_category(c) for c in (pcats if isinstance(pcats, list) else [pcats])]
                rec = {"id": pid, "name": name, "article": article, "hardwareRevision": hw,
                       "description": sanitize_line(data.get("description", "")),
                       "categories": [c for c in pcats if c], "revision": 1,
                       "status": "Aktiv", "updated": now_local().strftime("%Y-%m-%d"),
                       "changeDate": now_local().strftime("%Y-%m-%d %H:%M"),
                       "changeAction": "Angelegt", "changeReason": "Erstellt",
                       "deleteRequest": None}
                products.append(rec)
                STORE.write_products(products)
                STORE.snapshot(f"Produkt angelegt durch {sess['username']}")
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/products/([^/]+)/restore$", path)
            if m and method == "POST":
                STORE.assert_perm(sess, ["products.delete"])
                pid = urllib.parse.unquote(m.group(1))
                data = self._read_json()
                reason = sanitize_line(data.get("reason", ""))
                if not reason:
                    raise WikiError(400, "Vor dem Wiederherstellen muss ein Grund angegeben werden.")
                products = STORE.read_products()
                arch = STORE.read_archived_products()
                cand = [p for p in arch if p["id"] == pid]
                if not cand:
                    raise WikiError(404, "Produkt nicht gefunden.")
                src = sorted(cand, key=lambda x: x.get("revision", 1))[-1]
                if any(p["id"] == pid for p in products):
                    raise WikiError(409, "Dieses Produkt existiert bereits.")
                rec = dict(src)
                rec.update(status="Aktiv", updated=now_local().strftime("%Y-%m-%d"),
                           changeDate=now_local().strftime("%Y-%m-%d %H:%M"),
                           changeAction="Wiederhergestellt", changeReason=reason)
                products.append(rec)
                STORE.write_products(products)
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                payload["savedProductId"] = pid
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/products/([^/]+)/request-delete$", path)
            if m:
                pid = urllib.parse.unquote(m.group(1))
                data = self._read_json()
                reason = sanitize_line(data.get("reason", ""))
                if not reason:
                    raise WikiError(400, "Vor dem Markieren muss ein Grund angegeben werden.")
                if len(reason) > 2000:
                    raise WikiError(400, "Grund zu lang (max. 2000 Zeichen).")
                if method == "POST":
                    STORE.assert_perm(sess, ["products.requestDelete"])
                    products = STORE.read_products()
                    t = next((p for p in products if p["id"] == pid), None)
                    if not t:
                        raise WikiError(404, "Produkt nicht gefunden.")
                    t["deleteRequest"] = {"by": sess["username"], "at": iso_now(), "reason": reason}
                    STORE.write_products(products)
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
                if method == "DELETE":
                    STORE.assert_perm(sess, ["products.delete"])
                    products = STORE.read_products()
                    t = next((p for p in products if p["id"] == pid), None)
                    if not t:
                        raise WikiError(404, "Produkt nicht gefunden.")
                    t["deleteRequest"] = None
                    STORE.write_products(products)
                    # Ablehnung als Vorschlag persistieren
                    sid = (now_local().strftime("%Y%m%d-%H%M%S%f")[:-3]
                           + f"-ablehnung-produkt-{secrets.token_hex(3)}")
                    atomic_write_json(STORE.suggestions_dir / f"{sid}.json", {
                        "kind": "product", "type": "delete", "status": "rejected",
                        "slug": "", "productId": pid, "title": t.get("name", ""),
                        "body": "", "fields": None, "note": reason,
                        "author": sess["username"], "authorDisplay": sess["displayName"],
                        "createdAt": iso_now(), "rejectionReason": reason,
                        "rejectedAt": iso_now(), "rejectedBy": sess["username"],
                        "processedAt": iso_now(), "processedBy": sess["username"],
                        "decision": "rejected"})
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
            m = re.match(r"^/api/products/([^/]+)$", path)
            if m:
                pid = urllib.parse.unquote(m.group(1))
                if method == "PUT":
                    STORE.assert_perm(sess, ["products.edit"])
                    data = self._read_json()
                    reason = sanitize_line(data.get("reason", ""))
                    if not reason:
                        raise WikiError(400, "Vor dem Aendern muss ein Grund angegeben werden.")
                    products = STORE.read_products()
                    t = next((p for p in products if p["id"] == pid), None)
                    if not t:
                        raise WikiError(404, "Produkt nicht gefunden.")
                    arch = STORE.read_archived_products()
                    arch.append({**t, "status": "Archiviert",
                                 "updated": now_local().strftime("%Y-%m-%d"),
                                 "changeDate": now_local().strftime("%Y-%m-%d %H:%M"),
                                 "changeAction": f"Archiviert vor Aenderung zu Revision {t['revision'] + 1}",
                                 "changeReason": reason})
                    STORE.write_archived_products(arch)
                    name = sanitize_line(data.get("name", t["name"]))
                    article = sanitize_line(data.get("article", data.get("artikel", t["article"])))
                    if not name:
                        raise WikiError(400, "Produktname fehlt.")
                    if not article:
                        raise WikiError(400, "Artikel ist ein Pflichtfeld.")
                    hw = sanitize_line(data.get("hardwareRevision", data.get("hardwarerevision", t.get("hardwareRevision", ""))))
                    pcats = data.get("categories", data.get("categoryIds", t["categories"]))
                    pcats = [normalize_category(c) for c in (pcats if isinstance(pcats, list) else [pcats])]
                    t.update(name=name, article=article, hardwareRevision=hw,
                             description=sanitize_line(data.get("description", t.get("description", ""))),
                             categories=[c for c in pcats if c],
                             revision=t["revision"] + 1, status="Aktiv",
                             updated=now_local().strftime("%Y-%m-%d"),
                             changeDate=now_local().strftime("%Y-%m-%d %H:%M"),
                             changeAction="Geaendert", changeReason=reason)
                    STORE.write_products(products)
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
                if method == "DELETE":
                    STORE.assert_perm(sess, ["products.delete", "products.archive"])
                    data = self._read_json()
                    reason = sanitize_line(data.get("reason", ""))
                    if not reason:
                        raise WikiError(400, "Vor dem Loeschen muss ein Grund angegeben werden.")
                    products = STORE.read_products()
                    t = next((p for p in products if p["id"] == pid), None)
                    if not t:
                        raise WikiError(404, "Produkt nicht gefunden.")
                    arch = STORE.read_archived_products()
                    arch.append({**t, "status": "Archiviert",
                                 "updated": now_local().strftime("%Y-%m-%d"),
                                 "changeDate": now_local().strftime("%Y-%m-%d %H:%M"),
                                 "changeAction": "Geloescht und archiviert",
                                 "changeReason": reason})
                    STORE.write_archived_products(arch)
                    STORE.write_products([p for p in products if p["id"] != pid])
                    cats = STORE.read_categories()
                    for c in cats:
                        c["products"] = [x for x in c["products"] if x != pid]
                    STORE.write_categories(cats)
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
            if path == "/api/uploads" and method == "POST":
                STORE.assert_perm(sess, ["articles.edit"])
                data = self._read_json()
                slug = sanitize_line(data.get("articleSlug", "medien"))
                files = data.get("files", [])
                self._send_json(200, {"files": STORE.save_uploaded_files(slug, files)})
                return
            if path == "/api/articles" and method == "POST":
                STORE.assert_perm(sess, ["articles.create"])
                data = self._read_json()
                title = sanitize_line(data.get("title", ""))
                if not title:
                    raise WikiError(400, "Titel fehlt.")
                slug = slugify(title)
                if STORE.find_article(slug):
                    raise WikiError(409, "Ein aktiver Artikel mit diesem Titel existiert bereits.")
                atts = list(data.get("attachments", []) or [])
                for a in STORE.save_uploaded_files(slug, data.get("attachmentFiles", []) or []):
                    atts.append(a)
                data["attachments"] = atts
                if data.get("body"):
                    data["body"] = STORE.inline_base64_to_files(str(data["body"]), slug)
                data["changedBy"] = sess["username"]
                STORE.filter_article_products(data, slug)
                final_related, rel_add, rel_remove = STORE.plan_related_sync(
                    slug, data.get("related", []), [])
                data["related"] = final_related
                md = STORE.new_article_markdown(data, 1, "Angelegt", "Erstellt")
                atomic_write_text(STORE.articles_dir / f"{slug}.md", md)
                STORE.apply_related_changes(slug, rel_add, rel_remove)
                STORE.snapshot(f"Artikel angelegt: {title}")
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                payload["savedSlug"] = slug
                self._send_json(200, payload)
                return
            if path == "/api/suggestions" and method == "GET":
                STORE.assert_perm(sess, ["articles.view"])
                alls = STORE.read_suggestions()
                if "articles.edit" not in STORE.role_perms(sess["role"]):
                    alls = [s for s in alls if s["author"] == sess["username"]]
                self._send_json(200, alls)
                return
            if path == "/api/suggestions" and method == "POST":
                STORE.assert_perm(sess, ["articles.suggest"])
                data = self._read_json()
                kind = sanitize_line(data.get("kind", "article")).lower()
                if kind != "product":
                    kind = "article"
                if kind == "product":
                    STORE.assert_perm(sess, ["products.view"])
                    pid = sanitize_line(data.get("productId", ""))
                    fields = data.get("fields")
                    note = sanitize_line(data.get("note", ""))
                    if not pid or not any(p["id"] == pid for p in STORE.read_products()):
                        raise WikiError(404, "Produkt nicht gefunden.")
                    if not isinstance(fields, dict):
                        raise WikiError(400, "Der Vorschlag ist leer.")
                    clean, filled = {}, 0
                    for fn in ("name", "article", "hardwareRevision", "description", "categories"):
                        if fn in fields:
                            if fn == "categories":
                                v = fields[fn]
                                vals = v if isinstance(v, list) else [v]
                                clean[fn] = [sanitize_line(x) for x in vals if sanitize_line(x)]
                            else:
                                clean[fn] = sanitize_line(fields[fn])
                            filled += 1
                    if filled == 0 and not note:
                        raise WikiError(400, "Der Vorschlag ist leer.")
                    prod = next(p for p in STORE.read_products() if p["id"] == pid)
                    sid = (now_local().strftime("%Y%m%d-%H%M%S%f")[:-3]
                           + f"-produkt-{pid}-{secrets.token_hex(3)}")
                    rec = {"kind": "product", "type": "change", "status": "open",
                           "slug": "", "productId": pid, "title": prod["name"],
                           "body": "", "fields": clean, "note": note,
                           "author": sess["username"], "authorDisplay": sess["displayName"],
                           "createdAt": iso_now(), "rejectionReason": "",
                           "rejectedAt": "", "rejectedBy": "",
                           "processedAt": "", "processedBy": "", "decision": ""}
                    atomic_write_json(STORE.suggestions_dir / f"{sid}.json", rec)
                    STORE.snapshot(f"Produktvorschlag von {sess['username']} fuer {rec['title']}")
                    self._send_json(200, {**rec, "id": sid})
                    return
                slug = sanitize_line(data.get("slug", ""))
                title = sanitize_line(data.get("title", ""))
                body = str(data.get("body", "") or "")
                note = sanitize_line(data.get("note", ""))
                if not slug:
                    raise WikiError(400, "Slug fehlt.")
                if not title and not body.strip():
                    raise WikiError(400, "Der Vorschlag ist leer.")
                if len(body) > 200000:
                    raise WikiError(400, "Vorschlag zu gross (max. 200000 Zeichen).")
                sid = (now_local().strftime("%Y%m%d-%H%M%S%f")[:-3]
                       + f"-{slug}-{secrets.token_hex(3)}")
                rec = {"kind": "article", "type": "change", "status": "open",
                       "slug": slug, "productId": "", "title": title, "body": body,
                       "fields": None, "note": note, "author": sess["username"],
                       "authorDisplay": sess["displayName"], "createdAt": iso_now(),
                       "rejectionReason": "", "rejectedAt": "", "rejectedBy": "",
                       "processedAt": "", "processedBy": "", "decision": ""}
                atomic_write_json(STORE.suggestions_dir / f"{sid}.json", rec)
                STORE.snapshot(f"Aenderungsvorschlag von {sess['username']} fuer {slug}")
                self._send_json(200, {**rec, "id": sid})
                return
            m = re.match(r"^/api/suggestions/([^/]+)/reject$", path)
            if m and method == "POST":
                STORE.assert_perm(sess, ["articles.edit"])
                sid = urllib.parse.unquote(m.group(1))
                data = self._read_json()
                reason = sanitize_line(data.get("reason", ""))
                if not reason or len(reason) > 2000:
                    raise WikiError(400, "Ablehnungsgrund fehlt oder zu lang (max. 2000).")
                fp = STORE.suggestions_dir / f"{sanitize_filename(sid)}.json"
                if ".." in sid or not fp.is_file():
                    raise WikiError(404, "Vorschlag nicht gefunden.")
                rec = json.loads(fp.read_text(encoding="utf-8-sig"))
                if rec.get("status", "open") != "open":
                    raise WikiError(400, "Der Vorschlag wurde bereits bearbeitet.")
                rec.update(status="rejected", rejectionReason=reason,
                           rejectedAt=iso_now(), rejectedBy=sess["username"],
                           processedAt=iso_now(), processedBy=sess["username"],
                           decision="rejected")
                atomic_write_json(fp, rec)
                self._send_json(200, {"ok": True})
                return
            m = re.match(r"^/api/suggestions/([^/]+)/accept$", path)
            if m and method == "POST":
                STORE.assert_perm(sess, ["articles.edit"])
                sid = urllib.parse.unquote(m.group(1))
                fp = STORE.suggestions_dir / f"{sanitize_filename(sid)}.json"
                if ".." in sid or not fp.is_file():
                    raise WikiError(404, "Vorschlag nicht gefunden.")
                rec = json.loads(fp.read_text(encoding="utf-8-sig"))
                if rec.get("status", "open") != "open":
                    raise WikiError(400, "Der Vorschlag wurde bereits bearbeitet.")
                # Vorschlag bleibt als accepted/Bearbeitet bestehen, bis der
                # Ersteller ihn per Acknowledge abschliesst (kein Archiv).
                if rec.get("kind") == "product":
                    pid = rec.get("productId", "")
                    products = STORE.read_products()
                    t = next((p for p in products if p["id"] == pid), None)
                    if not t:
                        raise WikiError(404, "Produkt nicht gefunden.")
                    arch = STORE.read_archived_products()
                    arch.append({**t, "status": "Archiviert",
                                 "changeAction": f"Archiviert vor Aenderung zu Revision {t['revision'] + 1}",
                                 "changeReason": rec.get("note") or "Vorschlag uebernommen"})
                    STORE.write_archived_products(arch)
                    fields = rec.get("fields") or {}
                    for fn in ("name", "article", "hardwareRevision", "description"):
                        if fn in fields and sanitize_line(fields[fn]):
                            t[fn] = sanitize_line(fields[fn])
                    if "categories" in fields:
                        t["categories"] = [normalize_category(c) for c in fields["categories"]]
                    t.update(revision=t["revision"] + 1,
                             changeAction="Geaendert",
                             changeReason=rec.get("note") or "Vorschlag uebernommen")
                    STORE.write_products(products)
                    rec.update(status="accepted", processedAt=iso_now(),
                               processedBy=sess["username"], decision="approved")
                    atomic_write_json(fp, rec)
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
                rec.update(status="accepted", processedAt=iso_now(),
                           processedBy=sess["username"], decision="approved")
                atomic_write_json(fp, rec)
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/suggestions/([^/]+)/acknowledge$", path)
            if m and method == "POST":
                # Ersteller (suggest) wie Pruefer (edit); Feinpruefung innen.
                perms = STORE.role_perms(sess["role"])
                if "articles.suggest" not in perms and "articles.edit" not in perms:
                    raise AuthError("Fuer diese Aktion fehlt die Berechtigung.")
                sid = urllib.parse.unquote(m.group(1))
                fp = STORE.suggestions_dir / f"{sanitize_filename(sid)}.json"
                if ".." in sid or not fp.is_file():
                    raise WikiError(404, "Vorschlag nicht gefunden.")
                rec = json.loads(fp.read_text(encoding="utf-8-sig"))
                if rec.get("status", "open") == "open":
                    raise WikiError(400, "Offene Vorschlaege muessen erst vom Administrator bearbeitet werden.")
                can_edit = "articles.edit" in perms
                if rec.get("author") != sess["username"] and not can_edit:
                    raise AuthError("Fuer diese Aktion fehlt die Berechtigung.")
                fp.unlink()
                self._send_json(200, {"ok": True})
                return
            m = re.match(r"^/api/suggestions/([^/]+)$", path)
            if m and method == "DELETE":
                sid = urllib.parse.unquote(m.group(1))
                fp = STORE.suggestions_dir / f"{sanitize_filename(sid)}.json"
                if ".." in sid or not fp.is_file():
                    raise WikiError(404, "Vorschlag nicht gefunden.")
                rec = json.loads(fp.read_text(encoding="utf-8-sig"))
                is_open = rec.get("status", "open") == "open"
                can_edit = "articles.edit" in STORE.role_perms(sess["role"])
                if is_open:
                    if rec.get("author") != sess["username"]:
                        raise WikiError(403, "Nur der Autor kann den Vorschlag zurueckziehen.")
                else:
                    if rec.get("author") != sess["username"] and not can_edit:
                        raise AuthError()
                fp.unlink()
                self._send_json(200, {"ok": True})
                return
            m = re.match(r"^/api/articles/([^/]+)/request-delete$", path)
            if m:
                slug = urllib.parse.unquote(m.group(1))
                data = self._read_json()
                reason = sanitize_line(data.get("reason", ""))
                if not reason or len(reason) > 2000:
                    raise WikiError(400, "Grund fehlt oder zu lang (max. 2000).")
                if method == "POST":
                    STORE.assert_perm(sess, ["articles.requestDelete"])
                    art = STORE.find_article(slug)
                    if not art:
                        raise WikiError(404, "Artikel nicht gefunden.")
                    meta = dict(art["meta"])
                    meta["delete_request_by"] = sess["username"]
                    meta["delete_request_at"] = iso_now()
                    meta["delete_request_reason"] = reason
                    # Frontmatter neu schreiben (Body unveraendert)
                    lines = ["---"]
                    kept = False
                    for ln in art["raw"].split("\n"):
                        if ln.strip() == "---" and not kept:
                            continue
                        kept = True
                        break
                    # einfacher: Datei via build-Funktion aktualisieren
                    order = ["title", "slug", "category", "categories", "tags", "owner",
                             "status", "updated", "summary", "products", "attachments",
                             "revision", "change_date", "change_action", "change_reason",
                             "changed_by", "related", "delete_request_by",
                             "delete_request_at", "delete_request_reason"]
                    out = ["---"]
                    for k in order:
                        if k in meta:
                            out.append(f"{k}: {meta[k]}")
                    for k, v in meta.items():
                        if k not in order and not k.startswith("original_"):
                            out.append(f"{k}: {v}")
                    out += ["---", "", art["body"], ""]
                    atomic_write_text(art["file"], "\n".join(out))
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
                if method == "DELETE":
                    STORE.assert_perm(sess, ["articles.delete"])
                    art = STORE.find_article(slug)
                    if not art:
                        raise WikiError(404, "Artikel nicht gefunden.")
                    meta = dict(art["meta"])
                    for k in ("delete_request_by", "delete_request_at", "delete_request_reason"):
                        meta.pop(k, None)
                    out = ["---"]
                    for k, v in meta.items():
                        out.append(f"{k}: {v}")
                    out += ["---", "", art["body"], ""]
                    atomic_write_text(art["file"], "\n".join(out))
                    sid = (now_local().strftime("%Y%m%d-%H%M%S%f")[:-3]
                           + f"-ablehnung-artikel-{secrets.token_hex(3)}")
                    atomic_write_json(STORE.suggestions_dir / f"{sid}.json", {
                        "kind": "article", "type": "delete", "status": "rejected",
                        "slug": slug, "productId": "", "title": art["title"],
                        "body": "", "fields": None, "note": reason,
                        "author": sess["username"], "authorDisplay": sess["displayName"],
                        "createdAt": iso_now(), "rejectionReason": reason,
                        "rejectedAt": iso_now(), "rejectedBy": sess["username"],
                        "processedAt": iso_now(), "processedBy": sess["username"],
                        "decision": "rejected"})
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
            m = re.match(r"^/api/articles/([^/]+)/restore$", path)
            if m and method == "POST":
                STORE.assert_perm(sess, ["articles.delete"])
                aslug = urllib.parse.unquote(m.group(1))
                data = self._read_json()
                reason = sanitize_line(data.get("reason", ""))
                if not reason:
                    raise WikiError(400, "Vor dem Wiederherstellen muss ein Grund angegeben werden.")
                # Archivdatei suchen
                cand = None
                if STORE.archive_dir.exists():
                    for f in STORE.archive_dir.rglob("*.md"):
                        raw = f.read_text(encoding="utf-8-sig")
                        meta, body = STORE.parse_frontmatter(raw)
                        if slugify(meta.get("slug", f.stem)) == aslug:
                            cand = (f, meta, body)
                            break
                if not cand:
                    raise WikiError(404, "Archivierter Artikel nicht gefunden.")
                f, meta, body = cand
                orig = slugify(meta.get("original_slug", meta.get("title", f.stem)))
                if STORE.find_article(orig):
                    raise WikiError(409, "Ein aktiver Artikel mit diesem Titel existiert bereits.")
                # Kategorie-Fallback
                cats = split_list(meta.get("original_categories", "")) or (
                    [meta["original_category"]] if meta.get("original_category") else [])
                cats = [normalize_category(c) for c in cats if normalize_category(c)]
                if not cats:
                    try:
                        cats = [STORE.build_payload()["categories"][0]]
                    except Exception:
                        cats = ["Wiki Anleitung"]
                rev = STORE.revision_of(meta)
                new_meta_lines = ["---", f"title: {meta.get('original_title', meta.get('title', orig))}",
                                  f"slug: {orig}", f"category: {cats[0]}",
                                  f"categories: {', '.join(cats)}",
                                  f"tags: {meta.get('tags', '')}",
                                  f"owner: {meta.get('owner', 'Wiki-Verantwortlicher')}",
                                  "status: Entwurf",
                                  f"updated: {now_local().strftime('%Y-%m-%d')}",
                                  f"summary: {meta.get('summary', '')}",
                                  f"products: {meta.get('products', '')}",
                                  f"attachments: {meta.get('attachments', '')}",
                                  f"revision: {rev}",
                                  f"change_date: {now_local().strftime('%Y-%m-%d %H:%M')}",
                                  "change_action: Wiederhergestellt",
                                  f"change_reason: {reason}",
                                  f"changed_by: {sess['username']}", "related: ", "---", "", body.strip(), ""]
                atomic_write_text(STORE.articles_dir / f"{orig}.md", "\n".join(new_meta_lines))
                f.unlink()
                payload = STORE.build_payload()
                payload["systemStatus"] = STORE.system_status()
                payload["savedSlug"] = orig
                self._send_json(200, payload)
                return
            m = re.match(r"^/api/articles/([^/]+)$", path)
            if m:
                slug = urllib.parse.unquote(m.group(1))
                if method == "PUT":
                    STORE.assert_perm(sess, ["articles.edit"])
                    STORE.assert_lock(slug, sess)
                    data = self._read_json()
                    related_provided = "related" in data
                    reason = sanitize_line(data.get("reason", ""))
                    if not reason:
                        raise WikiError(400, "Vor dem Aendern muss ein Grund angegeben werden.")
                    art = STORE.find_article(slug)
                    if not art:
                        raise WikiError(404, "Artikel nicht gefunden.")
                    cur_rev = STORE.revision_of(art["meta"])
                    if "baseRevision" in data and int(data["baseRevision"]) != cur_rev:
                        raise WikiError(409, "Der Artikel wurde zwischenzeitlich geaendert. Bitte lade ihn neu.")
                    new_title = sanitize_line(data.get("title", art["title"]))
                    new_slug = slugify(new_title)
                    if new_slug != slug and STORE.find_article(new_slug):
                        raise WikiError(409, "Ein aktiver Artikel mit dem neuen Titel existiert bereits.")
                    atts = data.get("attachments", None)
                    if atts is None:
                        atts = split_list("")  # Platzhalter
                        # vorhandene aus Meta uebernehmen
                        raw_att = art["meta"].get("attachments", "")
                        atts = [{"path": p["path"], "name": p["name"]} for p in
                                ([{"path": e.split("|")[0].strip(),
                                   "name": e.split("|")[1].strip() if "|" in e else e.strip()}
                                  for e in raw_att.split(";") if e.strip()])]
                    else:
                        atts = list(atts)
                    for a in STORE.save_uploaded_files(new_slug, data.get("attachmentFiles", []) or []):
                        atts.append(a)
                    data["attachments"] = atts
                    if data.get("body"):
                        data["body"] = STORE.inline_base64_to_files(str(data["body"]), new_slug)
                    for k, fb in (("products", None), ("categories", None), ("related", None)):
                        if k not in data:
                            if k == "products":
                                data[k] = split_list(art["meta"].get("products", ""))
                            elif k == "categories":
                                data[k] = split_list(art["meta"].get("categories", "")) or (
                                    [art["meta"].get("category", "")] if art["meta"].get("category") else [])
                            else:
                                data[k] = split_list(art["meta"].get("related", ""))
                    if "deleteRequest" not in data:
                        if art["meta"].get("delete_request_by"):
                            data["deleteRequest"] = {"by": art["meta"]["delete_request_by"],
                                                     "at": art["meta"].get("delete_request_at", ""),
                                                     "reason": art["meta"].get("delete_request_reason", "")}
                    data["title"] = new_title
                    data["changedBy"] = sess["username"]
                    STORE.filter_article_products(data, new_slug)
                    base_related = data.get("relatedBase")
                    if not isinstance(base_related, list):
                        base_related = None
                    if not related_provided:
                        # Kein related-Feld im Request: bestehende (auch
                        # gegenlaeufige) Links unveraendert uebernehmen.
                        rel_map = STORE.read_active_related_map()
                        data["related"] = STORE.effective_related(slug, rel_map)
                        base_related = None
                    final_related, rel_add, rel_remove = STORE.plan_related_sync(
                        new_slug, data.get("related", []), base_related)
                    data["related"] = final_related
                    # Archivkopie
                    stamp = now_local().strftime("%Y%m%d-%H%M%S")
                    aslug = f"archiv-{stamp}-{slug}-r{cur_rev}"
                    # Archiv-Markdown vereinfacht aus Original + Log-Eintrag
                    elog = STORE.revision_log(art["body"])
                    abody = STORE.add_revision_entry(art["body"], elog, cur_rev,
                                                     f"Archiviert vor Aenderung zu Revision {cur_rev + 1}",
                                                     reason, sess["username"])
                    atomic_write_text(STORE.archive_dir / f"{aslug}.md",
                                      "\n".join(["---", f"title: Archiv: {art['title']} (Revision {cur_rev})",
                                                 f"slug: {aslug}", "category: Archiv",
                                                 f"original_slug: {slug}",
                                                 f"original_title: {art['title']}",
                                                 f"original_category: {art['meta'].get('category', '')}",
                                                 f"original_categories: {art['meta'].get('categories', '')}",
                                                 "categories: Archiv",
                                                 f"tags: {art['meta'].get('tags', '')}",
                                                 f"owner: {art['meta'].get('owner', '')}",
                                                 "status: Archiviert",
                                                 f"updated: {now_local().strftime('%Y-%m-%d')}",
                                                 f"summary: Archivierte Fassung von {art['title']}.",
                                                 f"products: {art['meta'].get('products', '')}",
                                                 f"attachments: {art['meta'].get('attachments', '')}",
                                                 f"revision: {cur_rev}",
                                                 f"change_date: {now_local().strftime('%Y-%m-%d %H:%M')}",
                                                 f"change_action: Archiviert vor Aenderung zu Revision {cur_rev + 1}",
                                                 f"change_reason: {reason}",
                                                 f"changed_by: {sess['username']}", "related: ",
                                                 "---", "", abody.strip(), ""]))
                    md = STORE.new_article_markdown(data, cur_rev + 1, "Geaendert", reason,
                                                    elog)
                    atomic_write_text(STORE.articles_dir / f"{new_slug}.md", md)
                    if (STORE.articles_dir / f"{new_slug}.md").resolve() != art["file"].resolve():
                        try:
                            art["file"].unlink()
                        except Exception:
                            pass
                    STORE.apply_related_changes(new_slug, rel_add, rel_remove,
                                                previous_slug=(slug if new_slug != slug else None))
                    if new_slug != slug:
                        STORE.rename_related_references(slug, new_slug)
                    STORE.release_lock(slug, sess)
                    STORE.snapshot(f"Artikel aktualisiert: {new_title}")
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    payload["savedSlug"] = new_slug
                    self._send_json(200, payload)
                    return
                if method == "DELETE":
                    STORE.assert_perm(sess, ["articles.delete", "articles.archive"])
                    STORE.assert_lock(slug, sess)
                    data = self._read_json()
                    reason = sanitize_line(data.get("reason", ""))
                    if not reason:
                        raise WikiError(400, "Vor dem Loeschen muss ein Grund angegeben werden.")
                    art = STORE.find_article(slug)
                    if not art:
                        raise WikiError(404, "Artikel nicht gefunden.")
                    cur_rev = STORE.revision_of(art["meta"])
                    stamp = now_local().strftime("%Y%m%d-%H%M%S")
                    aslug = f"archiv-{stamp}-{slug}-r{cur_rev}"
                    elog = STORE.revision_log(art["body"])
                    abody = STORE.add_revision_entry(art["body"], elog, cur_rev,
                                                     "Geloescht und archiviert", reason, sess["username"])
                    atomic_write_text(STORE.archive_dir / f"{aslug}.md",
                                      "\n".join(["---", f"title: Archiv: {art['title']} (Revision {cur_rev})",
                                                 f"slug: {aslug}", "category: Archiv",
                                                 f"original_slug: {slug}",
                                                 f"original_title: {art['title']}",
                                                 "categories: Archiv",
                                                 f"revision: {cur_rev}",
                                                 f"change_date: {now_local().strftime('%Y-%m-%d %H:%M')}",
                                                 "change_action: Geloescht und archiviert",
                                                 f"change_reason: {reason}",
                                                 f"changed_by: {sess['username']}", "---", "",
                                                 abody.strip(), ""]))
                    art["file"].unlink()
                    STORE.release_lock(slug, sess)
                    payload = STORE.build_payload()
                    payload["systemStatus"] = STORE.system_status()
                    self._send_json(200, payload)
                    return
            if path == "/api/backup/create" and method == "POST":
                self._send_json(200, STORE.create_backup(self._read_json(), sess))
                return
            if path == "/api/backup/restore" and method == "POST":
                self._send_json(200, STORE.restore_backup(self._read_json(), sess))
                return
            m = re.match(r"^/api/backup/download/([^/]+)$", path)
            if m and method == "GET":
                STORE.assert_backup_admin(sess)
                name = sanitize_filename(urllib.parse.unquote(m.group(1)))
                if not re.match(r"^wiki-backup-[0-9-]+\.zip$", name):
                    raise WikiError(404, "Unbekannte Backup-Datei.")
                full = (STORE.backup_dir / name).resolve()
                try:
                    full.relative_to(STORE.backup_dir.resolve())
                except Exception:
                    raise WikiError(404, "Backup-Datei nicht gefunden.")
                if not full.is_file():
                    raise WikiError(404, "Backup-Datei nicht gefunden.")
                return self._send_download(full, name)
            if method == "GET":
                return self._serve_file(path)
            self._send_error(405, "Methode nicht erlaubt.")
        except AuthError as e:
            self._send_error(403, e.message)
        except WikiError as e:
            self._send_error(e.status, e.message)
        except Exception as e:
            msg = str(e) or "Unbekannter Fehler."
            if re.search(r"gesperrt|zwischenzeitlich|bearbeitet|existiert bereits", msg):
                self._send_error(409, msg)
            else:
                self._send_error(400, msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    args = ap.parse_args()
    global STORE
    STORE = WikiStore(Path(args.root).resolve())
    # initialer Build (Cache-Datei)
    try:
        STORE.build_payload()
    except Exception as e:
        print(f"Build-Warnung: {e}")
    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    srv.daemon_threads = True
    print(f"Wiki Linux-Server laeuft: http://127.0.0.1:{args.port}/ (Bind: {args.bind})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
