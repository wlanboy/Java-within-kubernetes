#!/usr/bin/env python3
"""Ressourcen-Check fuer die hello-world Pods (CPU/Memory/JVM), Python-Nachbau von check.sh
mit strukturierter, eingefaerbter Ausgabe. Nutzt nur die Standardbibliothek."""

import os
import re
import shutil
import subprocess
import sys
import time

NAMESPACE = os.environ.get("NAMESPACE", "demo")
SELECTOR = os.environ.get("SELECTOR", "app=hello-world")
CONTAINER = os.environ.get("CONTAINER", "hello-world")
INTERVAL = float(os.environ.get("INTERVAL", "5"))
KUBECTL_TIMEOUT = 15  # Sekunden; verhindert Haenger, falls der Cluster nicht erreichbar ist


# ---------- Terminal-Ausgabe ----------

USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


def bold(t): return _c("1", t)
def dim(t): return _c("2", t)
def cyan(t): return _c("36;1", t)
def green(t): return _c("32", t)
def yellow(t): return _c("33", t)
def red(t): return _c("31", t)


def term_width():
    return shutil.get_terminal_size(fallback=(100, 24)).columns


def section(title):
    width = min(term_width(), 100)
    line = "─" * max(width - len(title) - 3, 3)
    print(f"\n{cyan('┌─ ' + title)} {dim(line)}")


def top_header(title):
    width = min(term_width(), 100)
    print(bold(cyan("═" * width)))
    print(bold(cyan(title.center(width))))
    print(bold(cyan("═" * width)))


def kv(label, value, indent=2):
    print(f"{' ' * indent}{label:<32} {value}")


def pct_color(pct, warn=60.0, crit=85.0):
    if pct >= crit:
        return red
    if pct >= warn:
        return yellow
    return green


def bar(pct, width=24, warn=60.0, crit=85.0):
    pct_clamped = max(0.0, min(100.0, pct))
    filled = int(round(width * pct_clamped / 100))
    color = pct_color(pct, warn, crit)
    b = "█" * filled + "░" * (width - filled)
    return f"{color('[' + b + ']')} {color(f'{pct:5.1f}%')}"


def warn_line(msg):
    print(f"  {yellow('⚠')} {msg}")


def info_line(msg):
    print(f"  {dim(msg)}")


# ---------- kubectl-Helfer ----------

def run(cmd, input_text=None):
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=KUBECTL_TIMEOUT, input=input_text
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 1, "", "timeout")
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 1, "", "kubectl nicht gefunden")


def kubectl_exec(pod, remote_cmd):
    """Fuehrt remote_cmd via `sh -c` im Container aus, liefert stdout (leer bei Fehler)."""
    cp = run(["kubectl", "exec", "-n", NAMESPACE, pod, "-c", CONTAINER, "--", "sh", "-c", remote_cmd])
    return cp.stdout if cp.returncode == 0 else ""


def kubectl_jsonpath(pod, jsonpath):
    cp = run(["kubectl", "get", "pod", "-n", NAMESPACE, pod, "-o", f"jsonpath={jsonpath}"])
    return cp.stdout.strip() if cp.returncode == 0 else ""


def parse_stat_file(content):
    """Parst 'key value'-Zeilen (cpu.stat, cpu.pressure-aehnlich) in ein dict."""
    result = {}
    for line in content.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            result[parts[0]] = parts[1]
    return result


def parse_cpu_quantity(raw):
    """'500m' -> 0.5, '1' -> 1.0, '' -> 0.0"""
    if not raw:
        return 0.0
    if raw.endswith("m"):
        try:
            return float(raw[:-1]) / 1000.0
        except ValueError:
            return 0.0
    try:
        return float(raw)
    except ValueError:
        return 0.0


def to_int(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# ---------- Kernlogik pro Pod ----------

def check_cpu(pod, cpu_limit_cores):
    cgroup_ver = kubectl_exec(pod, "[ -f /sys/fs/cgroup/cpu.stat ] && echo v2 || echo v1").strip() or "unknown"

    if cgroup_ver == "v2":
        stat1 = parse_stat_file(kubectl_exec(pod, "cat /sys/fs/cgroup/cpu.stat 2>/dev/null"))
        time.sleep(INTERVAL)
        stat2 = parse_stat_file(kubectl_exec(pod, "cat /sys/fs/cgroup/cpu.stat 2>/dev/null"))

        usage_delta_s = (to_int(stat2.get("usage_usec")) - to_int(stat1.get("usage_usec"))) / 1_000_000
        periods_delta = to_int(stat2.get("nr_periods")) - to_int(stat1.get("nr_periods"))
        throttled_delta = to_int(stat2.get("nr_throttled")) - to_int(stat1.get("nr_throttled"))
        throttled_ms = (to_int(stat2.get("throttled_usec")) - to_int(stat1.get("throttled_usec"))) / 1000

        psi = kubectl_exec(pod, "cat /sys/fs/cgroup/cpu.pressure 2>/dev/null").strip()
        quota = kubectl_exec(pod, "cat /sys/fs/cgroup/cpu.max 2>/dev/null").strip()

    elif cgroup_ver == "v1":
        usage1 = to_int(kubectl_exec(pod, "cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null").strip())
        stat1 = parse_stat_file(kubectl_exec(pod, "cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null"))
        time.sleep(INTERVAL)
        usage2 = to_int(kubectl_exec(pod, "cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null").strip())
        stat2 = parse_stat_file(kubectl_exec(pod, "cat /sys/fs/cgroup/cpu/cpu.stat 2>/dev/null"))

        usage_delta_s = (usage2 - usage1) / 1_000_000_000
        periods_delta = to_int(stat2.get("nr_periods")) - to_int(stat1.get("nr_periods"))
        throttled_delta = to_int(stat2.get("nr_throttled")) - to_int(stat1.get("nr_throttled"))
        throttled_ms = (to_int(stat2.get("throttled_time")) - to_int(stat1.get("throttled_time"))) / 1_000_000

        psi = None
        quota = kubectl_exec(
            pod,
            'echo "quota_us=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) '
            'period_us=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"',
        ).strip()
    else:
        warn_line("Cgroup-Version konnte nicht ermittelt werden (kein Zugriff auf /sys/fs/cgroup?).")
        return cgroup_ver

    section(f"CPU ({cgroup_ver}, letzte {INTERVAL:g}s)")
    cpu_pct = (usage_delta_s / (INTERVAL * cpu_limit_cores) * 100) if cpu_limit_cores > 0 else 0.0
    kv("CPU-Zeit verbraucht", f"{usage_delta_s:.3f}s / {INTERVAL:g}s  {bar(cpu_pct)}")

    throttle_pct = (throttled_delta / periods_delta * 100) if periods_delta > 0 else 0.0
    kv(
        "Throttled Periods",
        f"{throttled_delta} von {periods_delta}  {bar(throttle_pct, warn=1.0, crit=10.0)}"
        f"  ({throttled_ms:.1f}ms)",
    )

    if cgroup_ver == "v2":
        kv("CPU Quota (cpu.max)", quota or dim("nicht lesbar"))
        if psi:
            kv("PSI (cpu.pressure)", psi.splitlines()[0] if psi else "")
            for extra in psi.splitlines()[1:]:
                kv("", extra)
        else:
            info_line("PSI nicht verfuegbar (Kernel-Feature evtl. deaktiviert)")
    else:
        kv("CPU Quota/Period", quota or dim("nicht lesbar"))

    return cgroup_ver


def check_memory(pod, cgroup_ver, mem_limit_raw):
    section(f"Memory (Limit: {mem_limit_raw or '?'})")

    if cgroup_ver == "v2":
        mem_current = to_int(kubectl_exec(pod, "cat /sys/fs/cgroup/memory.current 2>/dev/null").strip())
        mem_max_raw = kubectl_exec(pod, "cat /sys/fs/cgroup/memory.max 2>/dev/null").strip()
        mem_max = None if mem_max_raw in ("", "max") else to_int(mem_max_raw)
    elif cgroup_ver == "v1":
        mem_current = to_int(kubectl_exec(pod, "cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null").strip())
        mem_max_raw = kubectl_exec(pod, "cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null").strip()
        mem_max_val = to_int(mem_max_raw)
        # v1 meldet bei "kein Limit" eine riesige Zahl nahe PAGE_COUNTER_MAX statt "max"
        mem_max = None if mem_max_val <= 0 or mem_max_val > (1 << 62) else mem_max_val
    else:
        mem_current, mem_max = 0, None

    rss_kb = to_int(kubectl_exec(pod, "awk '/VmRSS/ {print $2}' /proc/1/status 2>/dev/null").strip())

    cur_mi = mem_current / 1024 / 1024
    rss_mi = rss_kb / 1024
    if mem_max:
        max_mi = mem_max / 1024 / 1024
        pct = cur_mi / max_mi * 100
        kv("cgroup memory.current", f"{cur_mi:.1f}Mi / {max_mi:.1f}Mi  {bar(pct)}")
    else:
        kv("cgroup memory.current", f"{cur_mi:.1f}Mi  {dim('(Limit nicht lesbar)')}")
    kv("Java-Prozess RSS", f"{rss_mi:.1f}Mi  {dim('(/proc/1/status)')}")


def check_jvm_memory(pod):
    section("Effektive JVM-Speicherwerte")

    raw_opts = kubectl_exec(pod, "tr '\\0' '\\n' < /proc/1/environ | sed -n 's/^JAVA_OPTS=//p'").strip()
    if not raw_opts:
        warn_line("JAVA_OPTS nicht aus /proc/1/environ lesbar (kein Zugriff oder Variable nicht gesetzt).")
        return

    flags_out = kubectl_exec(
        pod,
        f"java {raw_opts} -XX:+PrintFlagsFinal -version 2>/dev/null "
        "| grep -E 'MaxHeapSize|InitialHeapSize|MaxMetaspaceSize|MaxDirectMemorySize|UsePerfData'",
    )
    if not flags_out.strip():
        warn_line("nicht ermittelbar (java im Container nicht ausfuehrbar?)")
        return

    pattern = re.compile(r"^\s*\S+\s+(\S+)\s*:?=\s*(\S+)")
    for line in flags_out.splitlines():
        m = pattern.match(line)
        if not m:
            continue
        name, value = m.group(1), m.group(2)
        if name == "UsePerfData":
            kv(name, value)
        else:
            kv(name, f"{to_int(value) / 1024 / 1024:.1f}Mi")

    info_line("Hinweis: konfigurierte Ergonomics-Werte, keine Live-Belegung -- das")
    info_line("JRE-Alpine-Image enthaelt kein jcmd/NMT fuer echte Metaspace-/Direct-")
    info_line("Memory-Verbrauchsmessung. Fuer echten Verbrauch: memory.current oben")
    info_line("unter Last beobachten.")


def check_aot_and_startup(pod):
    section("AOT-Verarbeitung & Startzeit (aus Pod-Logs)")
    cp = run(["kubectl", "logs", "-n", NAMESPACE, pod, "-c", CONTAINER])
    logs = cp.stdout if cp.returncode == 0 else ""

    aot_line = next((l for l in logs.splitlines() if "AOT-processed" in l), None)
    started_line = next((l for l in logs.splitlines() if re.search(r"Started .* in [0-9.]+ seconds", l)), None)

    if aot_line:
        kv("AOT aktiv", green(aot_line.strip()))
    else:
        warn_line("Kein 'AOT-processed' in den Logs gefunden (spring.aot.enabled evtl. nicht wirksam oder rotiert).")

    if started_line:
        kv("Startzeit", started_line.strip())
    else:
        warn_line("Keine Startzeit-Zeile in den Logs gefunden.")


def main():
    top_header("hello-world Ressourcen-Check")

    section("kubectl top (metrics-server)")
    cp = run(["kubectl", "top", "pods", "-n", NAMESPACE, "-l", SELECTOR])
    if cp.returncode == 0 and cp.stdout.strip():
        for line in cp.stdout.splitlines():
            print(f"  {line}")
    else:
        warn_line("metrics-server nicht verfuegbar oder kein Zugriff")

    cp = run(["kubectl", "get", "pods", "-n", NAMESPACE, "-l", SELECTOR, "-o", "jsonpath={.items[*].metadata.name}"])
    pods = cp.stdout.split() if cp.returncode == 0 else []
    if not pods:
        print(red(f"\nKeine Pods mit Selector '{SELECTOR}' in Namespace '{NAMESPACE}' gefunden."))
        sys.exit(1)

    for pod in pods:
        top_header(f"Pod: {pod}")

        cpu_limit_raw = kubectl_jsonpath(pod, f'{{.spec.containers[?(@.name=="{CONTAINER}")].resources.limits.cpu}}')
        cpu_req_raw = kubectl_jsonpath(pod, f'{{.spec.containers[?(@.name=="{CONTAINER}")].resources.requests.cpu}}')
        mem_limit_raw = kubectl_jsonpath(pod, f'{{.spec.containers[?(@.name=="{CONTAINER}")].resources.limits.memory}}')
        kv("Resources", f"requests.cpu={cpu_req_raw or '?'}  limits.cpu={cpu_limit_raw or '?'}")

        cpu_limit_cores = parse_cpu_quantity(cpu_limit_raw)
        cgroup_ver = check_cpu(pod, cpu_limit_cores)
        check_memory(pod, cgroup_ver, mem_limit_raw)
        check_jvm_memory(pod)
        check_aot_and_startup(pod)

    print()


if __name__ == "__main__":
    main()
