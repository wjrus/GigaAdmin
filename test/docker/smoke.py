#!/usr/bin/env python3
"""Exercise a fresh disposable installation, creating one synthetic administrator.

Only loopback URLs are accepted. Do not run against an installation with real data.
Uses the actual HTTP forms, session cookies, and CSRF tokens without printing them.
"""

import http.cookiejar
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class SmokeFailure(Exception):
    pass


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


class Forms(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.forms = []
        self.current = None
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "form":
            self.current = {
                "action": attributes.get("action", ""),
                "fields": {},
                "inputs": set(),
            }
        elif tag == "input" and self.current is not None:
            name = attributes.get("name")
            if name:
                self.current["inputs"].add(name)
                if attributes.get("type") == "hidden":
                    self.current["fields"][name] = attributes.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form" and self.current is not None:
            self.forms.append(self.current)
            self.current = None

    def find(self, action):
        for form in self.forms:
            if urllib.parse.urlsplit(form["action"]).path == action:
                return form
        raise SmokeFailure(f"Expected form for {action} was missing")


class Page(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.frames = []
        self.full_document = False
        self.navigation = False
        self.loading = False
        self.text = []
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == "html":
            self.full_document = True
        elif tag == "turbo-frame" and attributes.get("id") == "page-content":
            self.frames.append(attributes)
        elif tag == "nav" and attributes.get("aria-label") == "Page navigation":
            self.navigation = True
        if attributes.get("data-deferred-page-target") == "loading" and attributes.get("role") == "status":
            self.loading = True

    def handle_data(self, data):
        self.text.append(data)


class Browser:
    def __init__(self, base_url):
        parsed = urllib.parse.urlsplit(base_url)
        if (
            parsed.scheme not in ("http", "https")
            or parsed.hostname not in ("localhost", "127.0.0.1", "::1")
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in ("", "/")
            or parsed.query
            or parsed.fragment
        ):
            raise SmokeFailure("GIGAADMIN_SMOKE_URL must be a loopback origin for a disposable installation")
        self.base_url = base_url.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
            NoRedirects(),
        )

    def request(self, path, fields=None, headers=None):
        """Use only origin-relative paths and the known deferred-frame header."""
        parsed = urllib.parse.urlsplit(path)
        if not path.startswith("/") or parsed.scheme or parsed.netloc or parsed.fragment:
            raise SmokeFailure("Smoke requests must use origin-relative paths")
        if headers is not None and headers != {"Turbo-Frame": "page-content"}:
            raise SmokeFailure("Only the page-content Turbo-Frame request header is supported")
        data = None if fields is None else urllib.parse.urlencode(fields).encode()
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html",
                **(headers or {}),
            },
        )
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        except (urllib.error.URLError, TimeoutError) as error:
            raise SmokeFailure(f"HTTP connection failed ({type(error).__name__})") from None
        with response:
            body = response.read(2 * 1024 * 1024 + 1)
            if len(body) > 2 * 1024 * 1024:
                raise SmokeFailure("Unexpectedly large HTTP response")
            return response.code, response.headers, body.decode("utf-8")


def expect_status(response, expected, step):
    if response[0] != expected:
        raise SmokeFailure(f"{step}: expected HTTP {expected}, received {response[0]}")


def expect_redirect(response, path, step):
    if response[0] not in (302, 303):
        raise SmokeFailure(f"{step}: expected a redirect, received HTTP {response[0]}")
    if urllib.parse.urlsplit(response[1].get("Location", "")).path != path:
        raise SmokeFailure(f"{step}: unexpected redirect destination")


def submit_form(browser, html, path, values):
    form = Forms(html).find(path)
    if not form["fields"].get("authenticity_token"):
        raise SmokeFailure(f"CSRF token missing from {path} form")
    return browser.request(path, {**form["fields"], **values})


def expect_admin_page(response):
    expect_status(response, 200, "Administrator account page")
    invitation = Forms(response[2]).find("/admin/invitations")
    if "admin_invitation[email]" not in invitation["inputs"]:
        raise SmokeFailure("The first account cannot invite additional administrators")


def expect_deferred_shell(response, path):
    expect_status(response, 200, f"{path} page shell")
    page = Page(response[2])
    if not page.full_document or not page.navigation or not page.loading:
        raise SmokeFailure(f"{path}: page shell must include the layout, navigation, and loading status")
    if len(page.frames) != 1 or page.frames[0].get("src") != path or page.frames[0].get("target") != "_top":
        raise SmokeFailure(f"{path}: expected one same-URL page-content frame targeting full navigation")


def expect_deferred_content(response, path, expected_text):
    expect_status(response, 200, f"{path} deferred content")
    page = Page(response[2])
    if page.full_document or len(page.frames) != 1:
        raise SmokeFailure(f"{path}: deferred response must contain one page-content frame without a full layout")
    frame = page.frames[0]
    if "src" in frame or frame.get("target") != "_top" or page.loading:
        raise SmokeFailure(f"{path}: deferred response must contain finished content, not another loading request")
    if expected_text not in " ".join(page.text):
        raise SmokeFailure(f"{path}: expected page content was missing")


def main():
    browser = Browser(os.environ.get("GIGAADMIN_SMOKE_URL", "http://localhost:3010"))
    email = "smoke-admin@example.invalid"
    password = secrets.token_urlsafe(32)

    expect_status(browser.request("/up"), 200, "Health check")
    expect_redirect(browser.request("/admin/users"), "/setup", "Anonymous request before setup")
    setup = browser.request("/setup")
    expect_status(setup, 200, "Fresh installation setup")

    credentials = {
        "admin_user[email]": email,
        "admin_user[password]": password,
        "admin_user[password_confirmation]": password,
    }
    expect_status(browser.request("/setup", credentials), 422, "Setup without a CSRF token")
    created = submit_form(browser, setup[2], "/setup", credentials)
    expect_redirect(created, "/", "First administrator creation")

    admin_page = browser.request("/admin/users")
    expect_admin_page(admin_page)
    expect_redirect(browser.request("/setup"), "/sign_in", "Setup closes after first account")

    frame_headers = {"Turbo-Frame": "page-content"}
    for path, expected_text in (("/stats", "Unavailable"), ("/maintenance", "Plex Data Refresh")):
        expect_deferred_shell(browser.request(path), path)
        expect_deferred_content(browser.request(path, headers=frame_headers), path, expected_text)

    signed_out = submit_form(browser, admin_page[2], "/sign_out", {"_method": "delete"})
    expect_redirect(signed_out, "/sign_in", "Sign out")
    expect_redirect(browser.request("/admin/users"), "/sign_in", "Signed-out admin request")
    expect_redirect(browser.request("/stats", headers=frame_headers), "/sign_in", "Signed-out deferred request")
    frame_sign_in = browser.request("/sign_in", headers=frame_headers)
    expect_status(frame_sign_in, 200, "Full sign-in response after deferred authentication expires")
    sign_in_page = Page(frame_sign_in[2])
    if not sign_in_page.full_document or sign_in_page.frames:
        raise SmokeFailure("Sign-in must remain a full page for the frame's authentication redirect handler")
    Forms(frame_sign_in[2]).find("/sign_in")

    sign_in = browser.request("/sign_in")
    expect_status(sign_in, 200, "Local sign-in form")
    rejected = submit_form(
        browser,
        sign_in[2],
        "/sign_in",
        {"session[email]": email, "session[password]": "incorrect-password"},
    )
    expect_status(rejected, 422, "Incorrect password")
    signed_in = submit_form(
        browser,
        rejected[2],
        "/sign_in",
        {"session[email]": email, "session[password]": password},
    )
    expect_redirect(signed_in, "/", "Password sign-in")
    expect_admin_page(browser.request("/admin/users"))
    print("Fresh-install smoke passed: health, CSRF, bootstrap, admin access, async shells/content, frame authentication, setup closure, sign-out, and password sign-in.")


if __name__ == "__main__":
    try:
        main()
    except SmokeFailure as error:
        print(f"Fresh-install smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
