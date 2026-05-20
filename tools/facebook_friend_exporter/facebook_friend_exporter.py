#!/usr/bin/env python3
"""
Facebook Friend Exporter

Best-effort helper that opens Facebook in Playwright, walks friend profiles,
downloads profile photos, and emits a FriendFinder-compatible package zip.

Notes:
- Facebook DOM and anti-automation behavior can change frequently.
- You may need to tweak selectors over time.
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.parse
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

try:
    import cv2
    import numpy as np
except ImportError:
    cv2 = None
    np = None

from playwright.async_api import BrowserContext, Error as PlaywrightError, Page, async_playwright

DEFAULT_FRIENDS_URL = "https://www.facebook.com/me/friends"
FACE_CASCADE_SCALE_FACTOR = 1.1
FACE_CASCADE_MIN_NEIGHBORS = 5
FACE_CASCADE_MIN_SIZE = (48, 48)


@dataclass
class CandidateFriend:
    name: str
    profile_url: str


def now_iso_z() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalize_facebook_url(raw_url: str) -> str:
    parsed = urllib.parse.urlparse(raw_url)
    scheme = parsed.scheme or "https"
    netloc = parsed.netloc or "www.facebook.com"
    path = parsed.path or "/"
    return urllib.parse.urlunparse((scheme, netloc, path.rstrip("/"), "", "", ""))


def derive_friend_id(profile_url: str) -> str:
    digest = hashlib.sha1(profile_url.encode("utf-8")).hexdigest()
    return digest[:24]


def sanitize_filename(value: str, fallback: str = "image") -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "_", value).strip("._")
    return cleaned or fallback


def guess_extension(url: str, content_type: str | None) -> str:
    if content_type:
        lowered = content_type.lower()
        if "jpeg" in lowered or "jpg" in lowered:
            return ".jpg"
        if "png" in lowered:
            return ".png"
        if "webp" in lowered:
            return ".webp"
        if "gif" in lowered:
            return ".gif"

    parsed = urllib.parse.urlparse(url)
    ext = Path(parsed.path).suffix.lower()
    if ext in {".jpg", ".jpeg", ".png", ".webp", ".gif"}:
        return ".jpg" if ext == ".jpeg" else ext
    return ".jpg"


def build_face_detector() -> Any:
    if cv2 is None:
        raise RuntimeError(
            "OpenCV is not installed. Install requirements with Python 3 before running this helper."
        )

    cascade_path = cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
    detector = cv2.CascadeClassifier(cascade_path)
    if detector.empty():
        raise RuntimeError(f"Failed to load face detector cascade from {cascade_path}")
    return detector


def image_contains_face(image_bytes: bytes, detector: Any) -> bool:
    if cv2 is None or np is None:
        raise RuntimeError(
            "OpenCV and numpy are required for face filtering. Install requirements first."
        )

    array = np.frombuffer(image_bytes, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    if image is None:
        return False

    grayscale = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    faces = detector.detectMultiScale(
        grayscale,
        scaleFactor=FACE_CASCADE_SCALE_FACTOR,
        minNeighbors=FACE_CASCADE_MIN_NEIGHBORS,
        minSize=FACE_CASCADE_MIN_SIZE,
    )
    return len(faces) > 0


def is_likely_profile_href(href: str) -> bool:
    if not href:
        return False
    if "facebook.com" not in href:
        return False

    lowered = href.lower()
    blocked = [
        "/friends",
        "/groups",
        "/marketplace",
        "/watch",
        "/gaming",
        "/events",
        "/photo",
        "/photos/",
        "/reel/",
        "/stories/",
        "/messages/",
        "/notifications",
        "/help/",
        "/privacy/",
        "/policies/",
        "/ads/",
        "/settings",
    ]
    if any(fragment in lowered for fragment in blocked):
        return False

    if "profile.php?id=" in lowered:
        return True

    parsed = urllib.parse.urlparse(href)
    path = parsed.path.strip("/")
    if not path:
        return False
    if "/" in path:
        return False
    if path in {"me", "friends", "home.php", "profile.php"}:
        return False
    return True


async def auto_scroll(page: Page, rounds: int = 20, pause_seconds: float = 1.0) -> None:
    for _ in range(rounds):
        await page.evaluate("window.scrollBy(0, document.body.scrollHeight)")
        await page.wait_for_timeout(int(pause_seconds * 1000))


async def extract_friend_candidates(page: Page, max_friends: int) -> list[CandidateFriend]:
    seen: set[str] = set()
    results: list[CandidateFriend] = []

    for _ in range(10):
        await auto_scroll(page, rounds=2, pause_seconds=1.0)
        raw_items: list[dict[str, Any]] = await page.evaluate(
            """
            () => {
              const anchors = Array.from(document.querySelectorAll('a[href]'));
              const out = [];
              for (const a of anchors) {
                const href = a.href || '';
                const txt = (a.textContent || '').trim();
                if (!href || !txt || txt.length < 2) continue;
                out.push({ href, name: txt });
              }
              return out;
            }
            """
        )

        for item in raw_items:
            href = normalize_facebook_url(str(item.get("href", "")))
            name = str(item.get("name", "")).strip()
            if not is_likely_profile_href(href):
                continue
            if href in seen:
                continue
            seen.add(href)
            results.append(CandidateFriend(name=name, profile_url=href))
            if max_friends > 0 and len(results) >= max_friends:
                return results

    return results


async def extract_image_urls(page: Page, limit: int) -> list[str]:
    if limit <= 0:
        return []

    all_urls: list[str] = []
    seen: set[str] = set()

    for _ in range(6):
        await auto_scroll(page, rounds=1, pause_seconds=0.8)
        urls: list[str] = await page.evaluate(
            """
            () => {
              const images = Array.from(document.querySelectorAll('img'));
              const out = [];
              for (const img of images) {
                const src = img.currentSrc || img.src || '';
                if (src) out.push(src);
              }
              return out;
            }
            """
        )

        for u in urls:
            if not isinstance(u, str):
                continue
            if not u.startswith("http"):
                continue
            lowered = u.lower()
            if "scontent" not in lowered and "fbcdn.net" not in lowered:
                continue
            if u in seen:
                continue
            seen.add(u)
            all_urls.append(u)
            if len(all_urls) >= limit:
                return all_urls

    return all_urls


async def extract_photo_thumbnail_urls(page: Page, limit: int) -> list[str]:
    if limit <= 0:
        return []

    all_urls: list[str] = []
    seen: set[str] = set()

    for _ in range(6):
        await auto_scroll(page, rounds=1, pause_seconds=0.8)
        urls: list[str] = await page.evaluate(
            """
            () => {
              const anchors = Array.from(document.querySelectorAll('a[href]'));
              const out = [];
              for (const anchor of anchors) {
                const href = anchor.href || '';
                const loweredHref = href.toLowerCase();
                const looksLikePhotoLink =
                  loweredHref.includes('photo.php') ||
                  loweredHref.includes('fbid=') ||
                  loweredHref.includes('/photos/') ||
                  loweredHref.includes('/media/set/') ||
                  loweredHref.includes('/photo/');

                if (!looksLikePhotoLink) continue;

                const img = anchor.querySelector('img');
                if (!img) continue;

                const src = img.currentSrc || img.src || '';
                if (!src) continue;
                out.push(src);
              }
              return out;
            }
            """
        )

        for url in urls:
            if not isinstance(url, str):
                continue
            if not url.startswith("http"):
                continue
            lowered = url.lower()
            if "scontent" not in lowered and "fbcdn.net" not in lowered:
                continue
            if url in seen:
                continue
            seen.add(url)
            all_urls.append(url)
            if len(all_urls) >= limit:
                return all_urls

    if all_urls:
        return all_urls

    return await extract_image_urls(page, limit)


async def find_profile_picture_set_url(context: BrowserContext, friend: CandidateFriend) -> str | None:
    async def verify_profile_pictures_album(set_url: str) -> bool:
        page = await context.new_page()
        try:
            await page.goto(set_url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_timeout(1200)
            text_blob: str = await page.evaluate(
                """
                () => {
                  const parts = [];
                  const title = document.title || '';
                  parts.push(title);

                                    const labels = Array.from(document.querySelectorAll('h1, h2, h3, [role="heading"], span, a'));
                                    for (const node of labels) {
                                        const txt = (node.textContent || '').trim();
                                        if (txt) parts.push(txt);
                  }

                                    const bodyText = (document.body && document.body.innerText) ? document.body.innerText : '';
                                    if (bodyText) parts.push(bodyText);

                  return parts.join(' | ');
                }
                """
            )

            lowered = text_blob.lower()
            return "profile pictures" in lowered or "profile picture" in lowered
        except PlaywrightError:
            return False
        finally:
            await page.close()

    page = await context.new_page()
    try:
        await page.goto(friend.profile_url, wait_until="domcontentloaded", timeout=30000)
        await page.wait_for_timeout(1500)

        candidates: list[dict[str, str]] = await page.evaluate(
            """
            () => {
              const anchors = Array.from(document.querySelectorAll('a[href]'));
              return anchors.map((anchor) => ({
                href: anchor.href || '',
                text: (anchor.textContent || '').trim(),
                ariaLabel: anchor.getAttribute('aria-label') || '',
                title: anchor.getAttribute('title') || ''
              }));
            }
            """
        )

        strict_profile_matches: list[str] = []
        profileish_matches: list[str] = []
        non_cover_fallback: list[str] = []
        seen: set[str] = set()

        for item in candidates:
            href = str(item.get("href", "")).strip()
            lowered_href = href.lower()
            if "set=" not in lowered_href:
                continue

            parsed = urllib.parse.urlparse(href)
            query = urllib.parse.parse_qs(parsed.query)
            set_value = query.get("set", [""])[0]
            if not set_value:
                continue

            set_url = f"https://www.facebook.com/media/set/?set={urllib.parse.quote(set_value, safe='.=') }"
            if set_url in seen:
                continue
            seen.add(set_url)

            label_blob = " ".join(
                [
                    item.get("text", ""),
                    item.get("ariaLabel", ""),
                    item.get("title", ""),
                    href,
                ]
            ).lower()

            if "cover" in label_blob or "timeline" in label_blob:
                continue

            if "profile pictures" in label_blob:
                strict_profile_matches.append(set_url)
            elif "profile" in label_blob:
                profileish_matches.append(set_url)
            else:
                non_cover_fallback.append(set_url)

        candidates_in_order = strict_profile_matches + profileish_matches + non_cover_fallback

        print(
            f"[debug] {friend.name}: set candidates profile_exact={len(strict_profile_matches)} "
            f"profileish={len(profileish_matches)} fallback={len(non_cover_fallback)}"
        )

        # Explicitly verify album pages to avoid grabbing cover-photo sets.
        for candidate in candidates_in_order:
            if await verify_profile_pictures_album(candidate):
                print(f"[info] {friend.name}: using verified profile pictures set -> {candidate}")
                return candidate

        # Last-resort heuristic: Facebook often surfaces cover first and profile second.
        if len(candidates_in_order) >= 2:
            print(
                f"[warn] {friend.name}: no verified profile set; "
                f"using heuristic second candidate -> {candidates_in_order[1]}"
            )
            return candidates_in_order[1]
        if candidates_in_order:
            print(
                f"[warn] {friend.name}: no verified profile set; "
                f"using first candidate -> {candidates_in_order[0]}"
            )
            return candidates_in_order[0]
        print(f"[warn] {friend.name}: no profile picture set discovered")
        return None
    except PlaywrightError as exc:
        print(f"[warn] Failed to discover profile picture set for {friend.name}: {exc}")
        return None
    finally:
        await page.close()


async def collect_friend_photo_urls(
    context: BrowserContext,
    friend: CandidateFriend,
    photos_per_friend: int,
) -> list[str]:
    urls: list[str] = []

    async def collect_from(url: str, remaining: int) -> list[str]:
        page = await context.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            await page.wait_for_timeout(1200)
            return await extract_photo_thumbnail_urls(page, remaining)
        except PlaywrightError as exc:
            print(f"[warn] Failed to scrape images from {url}: {exc}")
            return []
        finally:
            await page.close()

    targets: list[tuple[str, str]] = []
    profile_picture_set_url = await find_profile_picture_set_url(context, friend)
    if profile_picture_set_url:
        targets.append(("profile_pictures_set", profile_picture_set_url))
        print(f"[info] {friend.name}: defaulting to profile pictures album first")
    else:
        print(f"[info] {friend.name}: profile pictures set unavailable, using photos_of")

    targets.append(("photos_of_fallback", f"{friend.profile_url}/photos_of"))

    for source_label, target in targets:
        if len(urls) >= photos_per_friend:
            break
        remaining = photos_per_friend - len(urls)
        if source_label == "profile_pictures_set":
            candidate_limit = max(remaining * 8, remaining + 20)
        else:
            candidate_limit = max(remaining * 4, remaining + 5)

        found = await collect_from(target, candidate_limit)
        print(
            f"[debug] {friend.name}: source={source_label} "
            f"collected_candidates={len(found)} requested_limit={candidate_limit}"
        )
        for image_url in found:
            if image_url not in urls:
                urls.append(image_url)
                if len(urls) >= max(photos_per_friend * 4, photos_per_friend + 5):
                    break

        if source_label == "photos_of_fallback" and profile_picture_set_url:
            print(f"[info] {friend.name}: used photos_of fallback due to insufficient profile-set candidates")

    return urls


async def download_image(
    context: BrowserContext,
    image_url: str,
    out_path: Path,
    detector: Any,
) -> tuple[bool, str]:
    try:
        response = await context.request.get(image_url, timeout=30000)
        if not response.ok:
            print(f"[warn] Download failed ({response.status}) for {image_url}")
            return False, "download_failed"

        body = await response.body()
        if not image_contains_face(body, detector):
            return False, "no_face"

        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_bytes(body)
        return True, "saved"
    except PlaywrightError as exc:
        print(f"[warn] Request error while downloading {image_url}: {exc}")
        return False, "request_error"
    except OSError as exc:
        print(f"[warn] File write error for {out_path}: {exc}")
        return False, "file_error"


def build_zip_from_dir(source_dir: Path, zip_path: Path) -> None:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(source_dir):
            for name in files:
                full_path = Path(root) / name
                rel_path = full_path.relative_to(source_dir)
                zf.write(full_path, arcname=str(rel_path))


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export Facebook friends and photos into a FriendFinder package zip."
    )
    parser.add_argument("--output", default="friends-package.zip", help="Output zip path")
    parser.add_argument(
        "--photos-per-friend",
        type=int,
        default=5,
        help="Maximum photos to collect per friend",
    )
    parser.add_argument(
        "--max-friends",
        type=int,
        default=0,
        help="Maximum friends to export (0 means all found)",
    )
    parser.add_argument("--headless", action="store_true", help="Run Chromium headless")
    parser.add_argument(
        "--profile-dir",
        default=".fb-browser-profile",
        help="Persistent Chromium profile directory",
    )
    parser.add_argument(
        "--friends-url",
        default=DEFAULT_FRIENDS_URL,
        help="Facebook friends URL",
    )
    return parser.parse_args(list(argv))


async def async_main(args: argparse.Namespace) -> int:
    if args.photos_per_friend < 0:
        print("[error] --photos-per-friend must be >= 0")
        return 2
    if args.max_friends < 0:
        print("[error] --max-friends must be >= 0")
        return 2

    exported_at = now_iso_z()
    temp_dir = Path(tempfile.mkdtemp(prefix="facebook_friend_exporter_"))
    package_root = temp_dir / "friends-package"
    images_dir = package_root / "images"
    package_root.mkdir(parents=True, exist_ok=True)
    images_dir.mkdir(parents=True, exist_ok=True)

    print("[warn] Facebook DOM and anti-automation behavior can change at any time.")
    print("[warn] If scraping fails, update selectors or navigate manually before pressing Enter.")

    total_candidates = 0
    total_exported_friends = 0
    total_downloaded_images = 0
    total_failed_images = 0
    total_rejected_non_faces = 0

    try:
        detector = build_face_detector()
        async with async_playwright() as playwright:
            context = await playwright.chromium.launch_persistent_context(
                user_data_dir=args.profile_dir,
                headless=args.headless,
            )

            try:
                page = context.pages[0] if context.pages else await context.new_page()
                await page.goto(args.friends_url, wait_until="domcontentloaded", timeout=45000)
                print(
                    "\nLog in to Facebook and confirm the friends page is ready.\n"
                    "Press Enter here to continue scraping..."
                )
                input()

                candidates = await extract_friend_candidates(page, args.max_friends)
                total_candidates = len(candidates)
                print(f"[info] Discovered {total_candidates} candidate profile links")

                friends_payload: list[dict[str, Any]] = []
                for index, friend in enumerate(candidates, start=1):
                    print(f"[info] Processing friend {index}/{total_candidates}: {friend.name}")
                    image_urls = await collect_friend_photo_urls(
                        context=context,
                        friend=friend,
                        photos_per_friend=args.photos_per_friend,
                    )

                    friend_id = derive_friend_id(friend.profile_url)
                    image_file_names: list[str] = []

                    for image_index, image_url in enumerate(image_urls, start=1):
                        if len(image_file_names) >= args.photos_per_friend:
                            break

                        ext = guess_extension(image_url, content_type=None)
                        base_name = sanitize_filename(friend.name, fallback=friend_id)
                        saved_index = len(image_file_names) + 1
                        image_name = f"{base_name}_{friend_id}_{saved_index}{ext}"
                        image_path = images_dir / image_name
                        success, reason = await download_image(context, image_url, image_path, detector)
                        if success:
                            image_file_names.append(image_name)
                            total_downloaded_images += 1
                        elif reason == "no_face":
                            total_rejected_non_faces += 1
                        else:
                            total_failed_images += 1

                    friend_entry = {
                        "id": friend_id,
                        "name": friend.name,
                        "nickname": "",
                        "note": "",
                        "imageFileNames": image_file_names,
                        "centroidEmbedding": [],
                        "updatedAt": now_iso_z(),
                    }
                    friends_payload.append(friend_entry)
                    total_exported_friends += 1

                package_json = {
                    "version": 2,
                    "exportedAt": exported_at,
                    "friends": friends_payload,
                    "tombstones": [],
                }

                package_json_path = package_root / "friends-package.json"
                package_json_path.write_text(
                    json.dumps(package_json, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )

                output_zip = Path(args.output).expanduser().resolve()
                build_zip_from_dir(package_root, output_zip)

                print("\nExport complete")
                print(f"  Candidates discovered: {total_candidates}")
                print(f"  Friends exported: {total_exported_friends}")
                print(f"  Images downloaded: {total_downloaded_images}")
                print(f"  Images rejected (no face): {total_rejected_non_faces}")
                print(f"  Images failed: {total_failed_images}")
                print(f"  Output zip: {output_zip}")
            finally:
                await context.close()

        return 0
    except KeyboardInterrupt:
        print("\n[error] Interrupted by user")
        return 130
    except PlaywrightError as exc:
        print(f"[error] Playwright failure: {exc}")
        return 1
    except Exception as exc:  # noqa: BLE001
        print(f"[error] Unexpected failure: {exc}")
        return 1
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


def main(argv: Iterable[str]) -> int:
    args = parse_args(argv)
    return asyncio.run(async_main(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
