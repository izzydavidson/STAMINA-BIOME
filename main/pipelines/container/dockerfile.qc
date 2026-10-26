FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONDONTWRITEBYTECODE=1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    findutils \
    gzip \
    jq \
    python3 \
    python3-pip \
    default-jre \
    fastqc \
  && rm -rf /var/lib/apt/lists/*

# Pin MultiQC so outputs don’t drift over time
RUN pip3 install --no-cache-dir "multiqc==1.25.1"

WORKDIR /work

# Quick sanity checks
RUN fastqc --version || true
RUN multiqc --version || true

# Write a tool manifest the dispatcher/UI can read later
RUN python3 - <<'PY'
import json, subprocess, os

def v(cmd):
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True)
        out = (out or "").strip()
        return out.splitlines()[0] if out else ""
    except Exception:
        return ""

manifest = {
    "fastqc": {"cmd": "fastqc --version", "version": v(["fastqc", "--version"])},
    "multiqc": {"cmd": "multiqc --version", "version": v(["multiqc", "--version"])},
    "python3": {"cmd": "python3 --version", "version": v(["python3", "--version"])},
    "jq": {"cmd": "jq --version", "version": v(["jq", "--version"])},
    "java": {"cmd": "java -version", "version": v(["bash", "-lc", "java -version 2>&1 | head -n 1"])},
}

os.makedirs("/opt/stamina-biome", exist_ok=True)
with open("/opt/stamina-biome/tool_manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)

print("Wrote /opt/stamina-biome/tool_manifest.json")
PY
