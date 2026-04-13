#!/bin/bash
# fix_bbbd.sh — Pre-upload BIDS validator fixes for BBBD (Madsen/Kuppa/Parra 2025)
# Run per-experiment dir. Archives self into code/ on completion.
set -euo pipefail

DS="${1:?usage: bash fix_bbbd.sh <experiment_dir>}"
[[ -d "$DS" ]] || { echo "Not found: $DS"; exit 1; }
cd "$DS"
echo "=== Fix BBBD at $DS ==="

# -------------------------------------------------------------------
# 1. Normalise participants.tsv values to match participants.json Levels
#    species: 'homo sapiens' / 'Homo sapiens' → 'homo_sapiens' (matches JSON Levels)
#    Tired:   'Very awake' → 'VeryAwake', 'Very tired' → 'VeryTired' (match JSON Levels)
#    *:       'NaN' → 'n/a' (BIDS convention)
# -------------------------------------------------------------------
echo "--- 1. Normalising participants.tsv values ---"
if [[ -f participants.tsv ]]; then
  python3 <<'PYEOF'
import csv
with open("participants.tsv") as f:
    rows = list(csv.reader(f, delimiter="\t"))
if not rows:
    raise SystemExit
header = rows[0]
idx = {h: i for i, h in enumerate(header)}
def fix(row, col, mapping):
    if col not in idx: return
    i = idx[col]
    if i < len(row):
        row[i] = mapping.get(row[i], row[i])
TIRED_MAP = {
    "Very awake": "VeryAwake",
    "very awake": "VeryAwake",
    "Very Awake": "VeryAwake",
    "Very tired": "VeryTired",
    "very tired": "VeryTired",
    "Very Tired": "VeryTired",
}
SPECIES_MAP = {
    "homo sapiens": "homo_sapiens",
    "Homo sapiens": "homo_sapiens",
    "Homo Sapiens": "homo_sapiens",
    "human": "homo_sapiens",
}
for r in rows[1:]:
    fix(r, "species", SPECIES_MAP)
    fix(r, "Tired", TIRED_MAP)
    # Replace NaN → n/a across all columns (BIDS missing-value convention)
    for i, v in enumerate(r):
        if v in {"NaN", "nan", "NAN", "NA", ""}:
            r[i] = "n/a"
with open("participants.tsv", "w") as f:
    w = csv.writer(f, delimiter="\t")
    w.writerows(rows)
print("  participants.tsv normalised (species/Tired levels + NaN→n/a)")
PYEOF
fi

# -------------------------------------------------------------------
# 2. Ensure .bidsignore covers non-BIDS paths (eyetrack is not a
#    standard BIDS modality; BBBD authors already ship one but some
#    validators don't honour wildcard patterns)
# -------------------------------------------------------------------
echo "--- 2. Merging separate eyetrack streams into BIDS-ET physio files ---"
# BIDS-EyeTracking physio requires initial columns:
#   timestamp, x_coordinate, y_coordinate
# BBBD splits these across three files per recording (pupil / gaze / head).
# We merge them into one `_physio.tsv.gz` + one `_physio.json` per
# (sub, ses, task) with PhysioType="eyetrack" and all columns declared.
# Source files are read either from beh/ (if previous run moved them there)
# or from derivatives/raw_eyetrack/ (if the derivative-fallback ran before).
python3 <<'PYEOF'
import json, gzip, re, shutil
from pathlib import Path
from collections import defaultdict

# Locate source eyetrack streams per (sub, ses, task)
# Sources can be in beh/ (named `*_recording-{label}_physio.{tsv.gz,json}`)
# or in derivatives/raw_eyetrack/ (the derivative-fallback from an earlier run)
# or in the original eyetrack/ (legacy `*_<label>_eyetrack.{tsv.gz,json}`)

ET_LABELS = {"pupil", "head", "gazevisualangle"}
FNAME_RE_PHYSIO = re.compile(r"(sub-[^_]+)_(ses-[^_]+)_(task-[^_]+)_recording-([^_]+)_physio\.(tsv\.gz|json)$")
FNAME_RE_ET = re.compile(r"(sub-[^_]+)_(ses-[^_]+)_(task-[^_]+)_(pupil|head|gaze_visualangle)_eyetrack\.(tsv\.gz|json)$")

# Index source files by (sub, ses, task) → {label: {"tsv": Path, "json": Path}}
index = defaultdict(lambda: defaultdict(dict))

for p in list(Path(".").rglob("*_physio.tsv.gz")) + list(Path(".").rglob("*_physio.json")):
    m = FNAME_RE_PHYSIO.search(p.name)
    if not m:
        continue
    sub, ses, task, label, ext = m.groups()
    if label not in ET_LABELS:
        continue
    ext_key = "tsv" if ext == "tsv.gz" else "json"
    index[(sub, ses, task)][label][ext_key] = p

for p in list(Path(".").rglob("*_eyetrack.tsv.gz")) + list(Path(".").rglob("*_eyetrack.json")):
    m = FNAME_RE_ET.search(p.name)
    if not m:
        continue
    sub, ses, task, raw_label, ext = m.groups()
    label = raw_label.replace("_", "")  # gaze_visualangle → gazevisualangle
    ext_key = "tsv" if ext == "tsv.gz" else "json"
    # Don't overwrite an already-indexed physio path
    if label not in index[(sub, ses, task)]:
        index[(sub, ses, task)][label][ext_key] = p
    else:
        index[(sub, ses, task)][label].setdefault(ext_key, p)

print(f"  Indexed {len(index)} (sub, ses, task) triples with eyetrack streams")

# Merge each triple into a single BIDS-ET physio file
merged_count = 0
for (sub, ses, task), labels in sorted(index.items()):
    # Need gaze to provide x/y, and we want pupil for optional pupil_size
    if "gazevisualangle" not in labels:
        continue  # cannot satisfy required x/y columns
    beh_dir = Path(sub) / ses / "beh"
    beh_dir.mkdir(parents=True, exist_ok=True)

    # Read JSONs to learn SamplingFrequency and per-column descriptions
    sf = None
    manufacturer_info = {}
    task_name = None
    for label, paths in labels.items():
        jp = paths.get("json")
        if not jp or not jp.exists():
            continue
        try:
            with open(jp) as f:
                jd = json.load(f)
        except Exception:
            continue
        sf = sf or jd.get("SamplingFrequency")
        task_name = task_name or jd.get("TaskName")
        for k in ("Manufacturer", "ManufacturersModelName", "SoftwareVersions", "DeviceSerialNumber", "TaskDescription"):
            if k in jd and k not in manufacturer_info:
                manufacturer_info[k] = jd[k]
    if sf is None:
        sf = 128  # BBBD default

    # Read streams
    def read_rows(path):
        with gzip.open(path, "rt") as f:
            return [line.rstrip("\n").split("\t") for line in f]

    gaze_rows = read_rows(labels["gazevisualangle"]["tsv"])
    pupil_rows = read_rows(labels["pupil"]["tsv"]) if "pupil" in labels else None
    head_rows = read_rows(labels["head"]["tsv"]) if "head" in labels else None

    n = len(gaze_rows)
    if pupil_rows is not None and len(pupil_rows) != n:
        # Align to the shorter stream
        n = min(n, len(pupil_rows))
        gaze_rows = gaze_rows[:n]
        pupil_rows = pupil_rows[:n]
        if head_rows is not None:
            head_rows = head_rows[:min(n, len(head_rows))]
    if head_rows is not None and len(head_rows) != n:
        n = min(n, len(head_rows))
        gaze_rows = gaze_rows[:n]
        if pupil_rows is not None:
            pupil_rows = pupil_rows[:n]
        head_rows = head_rows[:n]

    # Build combined rows
    # Assumed column layouts (verified from BBBD samples):
    #   gazevisualangle: gaze_x_px, gaze_y_px, visual_angle_x_deg, visual_angle_y_deg
    #   pupil:           pupil_size_area
    #   head:            head_x, head_y, head_z (3 columns — if different, we still concatenate)
    out_path = beh_dir / f"{sub}_{ses}_{task}_physio.tsv.gz"
    with gzip.open(out_path, "wt") as f:
        for i in range(n):
            t = f"{i/sf:.6f}"
            parts = [t]
            parts += gaze_rows[i][:4]
            if pupil_rows is not None:
                parts += pupil_rows[i][:1]
            if head_rows is not None:
                parts += head_rows[i][:3]
            f.write("\t".join(parts) + "\n")

    # Build sidecar.
    # Column semantics verified against pristine BBBD JSON sidecars from
    # experiment*.zip (before overwrite):
    #   gazevisualangle — Columns: ["x", "y", "vdx", "vdy"]
    #     x   — gaze horizontal position, screen pixels
    #     y   — gaze vertical position, screen pixels
    #     vdx — visual angle horizontal, degrees
    #     vdy — visual angle vertical, degrees
    #   pupil — Columns: ["pupil_size"]
    #     pupil_size — LEFT pupil size in area, camera sensor pixels
    #   head — Columns: ["x", "y", "z"]
    #     x, y — head position from EyeLink camera, screen pixels
    #     z    — head distance from camera sensor, millimetres
    sidecar = {
        "TaskName": task_name or task.replace("task-", ""),
        "SamplingFrequency": sf,
        "StartTime": 0,
        "PhysioType": "eyetrack",
        # BBBD's pupil JSON explicitly describes 'left pupil size in area' →
        # RecordedEye is the left eye (monocular), not cyclopean.
        "RecordedEye": "left",
        "SampleCoordinateUnits": "pixels",
        "SampleCoordinateSystem": "gaze-on-screen",
        "Columns": [
            "timestamp",
            "x_coordinate",
            "y_coordinate",
            "visual_angle_x",
            "visual_angle_y",
        ],
        "timestamp":      {"Description": "Sample time since recording start (computed from SamplingFrequency assuming fixed-rate export; EyeLink may emit NaN rows for blinks but at the same sample cadence)", "Units": "s"},
        "x_coordinate":   {"Description": "Gaze position, horizontal axis (EyeLink gazevisualangle column 'x')", "Units": "pixels"},
        "y_coordinate":   {"Description": "Gaze position, vertical axis (EyeLink gazevisualangle column 'y')", "Units": "pixels"},
        "visual_angle_x": {"Description": "Gaze in visual angle, horizontal axis (EyeLink gazevisualangle column 'vdx')", "Units": "deg"},
        "visual_angle_y": {"Description": "Gaze in visual angle, vertical axis (EyeLink gazevisualangle column 'vdy')", "Units": "deg"},
    }
    if pupil_rows is not None:
        sidecar["Columns"].append("pupil_size")
        sidecar["pupil_size"] = {
            "Description": "Left pupil area, in EyeLink camera sensor units (see BBBD pupil_eyetrack.json)",
            "Units": "camera sensor pixels",
        }
    if head_rows is not None:
        sidecar["Columns"].extend(["head_x", "head_y", "head_z"])
        sidecar["head_x"] = {"Description": "Head position from EyeLink camera, horizontal axis", "Units": "pixels"}
        sidecar["head_y"] = {"Description": "Head position from EyeLink camera, vertical axis", "Units": "pixels"}
        sidecar["head_z"] = {"Description": "Head distance from EyeLink camera sensor", "Units": "mm"}
    sidecar.update(manufacturer_info)

    with open(beh_dir / f"{sub}_{ses}_{task}_physio.json", "w") as f:
        json.dump(sidecar, f, indent=2)
        f.write("\n")
    merged_count += 1

    # Delete the source streams we consumed
    for paths in labels.values():
        for p in paths.values():
            try:
                if p.exists():
                    p.unlink()
            except Exception:
                pass

print(f"  Merged {merged_count} triples into BIDS-ET physio files (beh/*_physio.tsv.gz)")

# Clean up now-empty eyetrack/ and derivatives/raw_eyetrack/ trees
for eyedir in list(Path(".").rglob("eyetrack")):
    if eyedir.is_dir():
        try:
            if not any(eyedir.iterdir()):
                eyedir.rmdir()
        except OSError:
            pass
deriv_et = Path("derivatives/raw_eyetrack")
if deriv_et.exists():
    for sub_et in list(deriv_et.glob("sub-*/ses-*")):
        try:
            if not any(sub_et.iterdir()):
                sub_et.rmdir()
        except OSError:
            pass
    for sub_et in list(deriv_et.glob("sub-*")):
        try:
            if not any(sub_et.iterdir()):
                sub_et.rmdir()
        except OSError:
            pass
    # Remove the dataset_description.json if the tree is effectively empty
    remaining = [p for p in deriv_et.rglob("*") if p.is_file() and p.name != "dataset_description.json"]
    if not remaining:
        for p in deriv_et.rglob("*"):
            try: p.unlink()
            except Exception: pass
        try: deriv_et.rmdir()
        except OSError: pass
        print("  derivatives/raw_eyetrack/ removed (all streams merged)")
PYEOF

# Minimal .bidsignore — remove previous overrides; keep only phenotype/ if present
if [[ -d phenotype ]]; then
  echo "phenotype/" > .bidsignore
  echo "  phenotype/ added to .bidsignore"
else
  rm -f .bidsignore
  echo "  .bidsignore removed (no non-BIDS dirs to ignore)"
fi

# -------------------------------------------------------------------
# 3. Archive this script into code/ for provenance
# -------------------------------------------------------------------
# -------------------------------------------------------------------
# 2b. NaN → n/a in all physio.tsv.gz files (ECG, eyetrack, etc.)
# -------------------------------------------------------------------
echo "--- 2b. Replacing 'NaN' → 'n/a' in *_physio.tsv.gz ---"
count=0
for f in $(find . -name "*_physio.tsv.gz"); do
  if zcat "$f" 2>/dev/null | grep -q "NaN" ; then
    tmp="${f}.tmp"
    zcat "$f" | sed 's/\bNaN\b/n\/a/g' | gzip -n > "$tmp"
    mv -f "$tmp" "$f"
    count=$((count + 1))
  fi
done
echo "  Fixed $count physio.tsv.gz"

echo "--- 3. Archiving fix script into code/ ---"
mkdir -p code
SELF="$(readlink -f "$0" 2>/dev/null || realpath "$0")"
[[ -f "$SELF" ]] && cp -f "$SELF" code/fix_bbbd.sh
chmod +x code/fix_bbbd.sh 2>/dev/null || true
echo "  archived → code/fix_bbbd.sh"

echo ""
echo "=== Done ==="
