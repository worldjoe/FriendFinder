# Facebook Friend Exporter
## Do NOT file bugs on this helper tool. It is unsupported.

This helper exports friend metadata and photos from your Facebook session into a FriendFinder import package ZIP.

It runs face detection on downloaded candidate photos and rejects images that do not contain a detectable face, then keeps trying additional images when available.

Warning:
- This automates a personal Facebook account session.
- You are responsible for complying with Facebook Terms, privacy requirements, and all applicable local laws.

## Setup

1. Install dependencies:

```bash
pip install -r requirements.txt
```

2. Install Chromium for Playwright:

```bash
playwright install chromium
```

## Usage

Example command:

```bash
python3 facebook_friend_exporter.py --output friends-package.zip --photos-per-friend 5 --max-friends 0 --profile-dir .fb-browser-profile
```

Available options:

- `--output` (default: `friends-package.zip`)
- `--photos-per-friend` (default: `5`)
- `--max-friends` (default: `0`, means all)
- `--headless` (flag)
- `--profile-dir` (default: `.fb-browser-profile`)
- `--friends-url` (default: `https://www.facebook.com/me/friends`)

## Output

The generated ZIP contains:

- `friends-package.json`
- `images/`

The output ZIP is importable in FriendFinder via the **Import JSON or Package** action.

## Face Filtering

- Candidate images are downloaded and checked with OpenCV face detection.
- Photos without a detectable face are discarded.
- The exporter keeps trying additional candidate photos until it reaches the requested `--photos-per-friend` limit or runs out of candidates.
