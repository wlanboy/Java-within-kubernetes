#!/usr/bin/env bash
set -euo pipefail

# feste C-Locale, damit awk/printf immer Punkt statt Komma als Dezimaltrenner nutzt
export LC_NUMERIC=C

NAMESPACE="${NAMESPACE:-demo}"
SELECTOR="${SELECTOR:-app=hello-world}"
INTERVAL="${INTERVAL:-5}"

echo "=== kubectl top (metrics-server) ==="
kubectl top pods -n "${NAMESPACE}" -l "${SELECTOR}" 2>/dev/null \
  || echo "metrics-server nicht verfuegbar oder kein Zugriff"

PODS=$(kubectl get pods -n "${NAMESPACE}" -l "${SELECTOR}" -o jsonpath='{.items[*].metadata.name}')
if [[ -z "${PODS}" ]]; then
  echo "Keine Pods mit Selector '${SELECTOR}' in Namespace '${NAMESPACE}' gefunden."
  exit 1
fi

# liest eine einzelne Zahl aus einer Cgroup-Datei im Container (0 falls nicht vorhanden)
read_stat() {
  local pod="$1" file="$2" key="$3"
  kubectl exec -n "${NAMESPACE}" "${pod}" -c hello-world -- \
    sh -c "cat ${file} 2>/dev/null" 2>/dev/null \
    | awk -v k="${key}" '$1==k {print $2}'
}

for POD in ${PODS}; do
  echo
  echo "=== Pod: ${POD} ==="

  CPU_LIMIT_RAW=$(kubectl get pod -n "${NAMESPACE}" "${POD}" \
    -o jsonpath='{.spec.containers[?(@.name=="hello-world")].resources.limits.cpu}')
  CPU_REQ_RAW=$(kubectl get pod -n "${NAMESPACE}" "${POD}" \
    -o jsonpath='{.spec.containers[?(@.name=="hello-world")].resources.requests.cpu}')
  echo "Resources: requests.cpu=${CPU_REQ_RAW:-?} limits.cpu=${CPU_LIMIT_RAW:-?}"

  # "500m" -> 0.5, "1" -> 1
  CPU_LIMIT_CORES=$(awk -v v="${CPU_LIMIT_RAW:-0}" 'BEGIN {
    if (v ~ /m$/) { sub(/m$/, "", v); printf "%f", v/1000 } else { printf "%f", v+0 }
  }')

  CGROUP_VER=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
    sh -c '[ -f /sys/fs/cgroup/cpu.stat ] && echo v2 || echo v1' 2>/dev/null || echo unknown)

  if [[ "${CGROUP_VER}" == "v2" ]]; then
    USAGE_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat usage_usec)
    PERIODS_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat nr_periods)
    THROTTLED_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat nr_throttled)
    THROTTLED_USEC_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat throttled_usec)

    sleep "${INTERVAL}"

    USAGE_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat usage_usec)
    PERIODS_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat nr_periods)
    THROTTLED_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat nr_throttled)
    THROTTLED_USEC_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu.stat throttled_usec)

    echo "--- CPU Usage (cgroup v2, letzte ${INTERVAL}s) ---"
    awk -v u1="${USAGE_1:-0}" -v u2="${USAGE_2:-0}" -v iv="${INTERVAL}" -v cores="${CPU_LIMIT_CORES}" 'BEGIN {
      delta_s = (u2 - u1) / 1000000
      pct = cores > 0 ? (delta_s / (iv * cores)) * 100 : 0
      printf "CPU-Zeit verbraucht: %.3fs / %ss  (~%.1f%% vom Limit)\n", delta_s, iv, pct
    }'

    echo "--- CPU Throttle (cgroup v2, letzte ${INTERVAL}s) ---"
    awk -v p1="${PERIODS_1:-0}" -v p2="${PERIODS_2:-0}" -v t1="${THROTTLED_1:-0}" -v t2="${THROTTLED_2:-0}" \
        -v tu1="${THROTTLED_USEC_1:-0}" -v tu2="${THROTTLED_USEC_2:-0}" 'BEGIN {
      dp = p2 - p1; dt = t2 - t1; dtu = (tu2 - tu1) / 1000
      pct = dp > 0 ? (dt / dp) * 100 : 0
      printf "Throttled Periods: %d von %d (%.1f%%), Throttled Time: %.1fms\n", dt, dp, pct, dtu
    }'

    echo "--- CPU Pressure / PSI (cgroup v2, seit Pod-Start gemittelt) ---"
    kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- cat /sys/fs/cgroup/cpu.pressure 2>/dev/null \
      || echo "PSI nicht verfuegbar (Kernel-Feature evtl. deaktiviert)"

    echo "--- CPU Quota (cgroup v2, cpu.max) ---"
    kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- cat /sys/fs/cgroup/cpu.max 2>/dev/null \
      || echo "nicht lesbar"

  elif [[ "${CGROUP_VER}" == "v1" ]]; then
    USAGE_1=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null || echo 0)
    PERIODS_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat nr_periods)
    THROTTLED_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat nr_throttled)
    THROTTLEDTIME_1=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat throttled_time)

    sleep "${INTERVAL}"

    USAGE_2=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      cat /sys/fs/cgroup/cpuacct/cpuacct.usage 2>/dev/null || echo 0)
    PERIODS_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat nr_periods)
    THROTTLED_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat nr_throttled)
    THROTTLEDTIME_2=$(read_stat "${POD}" /sys/fs/cgroup/cpu/cpu.stat throttled_time)

    echo "--- CPU Usage (cgroup v1, letzte ${INTERVAL}s) ---"
    awk -v u1="${USAGE_1:-0}" -v u2="${USAGE_2:-0}" -v iv="${INTERVAL}" -v cores="${CPU_LIMIT_CORES}" 'BEGIN {
      delta_s = (u2 - u1) / 1000000000
      pct = cores > 0 ? (delta_s / (iv * cores)) * 100 : 0
      printf "CPU-Zeit verbraucht: %.3fs / %ss  (~%.1f%% vom Limit)\n", delta_s, iv, pct
    }'

    echo "--- CPU Throttle (cgroup v1, letzte ${INTERVAL}s) ---"
    awk -v p1="${PERIODS_1:-0}" -v p2="${PERIODS_2:-0}" -v t1="${THROTTLED_1:-0}" -v t2="${THROTTLED_2:-0}" \
        -v tt1="${THROTTLEDTIME_1:-0}" -v tt2="${THROTTLEDTIME_2:-0}" 'BEGIN {
      dp = p2 - p1; dt = t2 - t1; dtt = (tt2 - tt1) / 1000000
      pct = dp > 0 ? (dt / dp) * 100 : 0
      printf "Throttled Periods: %d von %d (%.1f%%), Throttled Time: %.1fms\n", dt, dp, pct, dtt
    }'

    echo "--- CPU Quota/Period (cgroup v1) ---"
    kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      sh -c 'echo "quota_us=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us) period_us=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)"' 2>/dev/null \
      || echo "nicht lesbar"

  else
    echo "Cgroup-Version konnte nicht ermittelt werden (kein Zugriff auf /sys/fs/cgroup im Container?)."
  fi

  # --- Memory: cgroup-Limit vs. tatsaechlicher Verbrauch (RSS) ---
  MEM_LIMIT_RAW=$(kubectl get pod -n "${NAMESPACE}" "${POD}" \
    -o jsonpath='{.spec.containers[?(@.name=="hello-world")].resources.limits.memory}')
  echo
  echo "--- Memory (Limit: ${MEM_LIMIT_RAW:-?}) ---"

  if [[ "${CGROUP_VER}" == "v2" ]]; then
    MEM_CURRENT=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      sh -c 'cat /sys/fs/cgroup/memory.current 2>/dev/null' 2>/dev/null || echo 0)
    MEM_MAX=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      sh -c 'cat /sys/fs/cgroup/memory.max 2>/dev/null' 2>/dev/null || echo 0)
  elif [[ "${CGROUP_VER}" == "v1" ]]; then
    MEM_CURRENT=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      sh -c 'cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null' 2>/dev/null || echo 0)
    MEM_MAX=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
      sh -c 'cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null' 2>/dev/null || echo 0)
  else
    MEM_CURRENT=0
    MEM_MAX=0
  fi

  # RSS des Java-Prozesses (PID 1, da entrypoint.sh "exec java ..." nutzt)
  RSS_KB=$(kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
    sh -c "awk '/VmRSS/ {print \$2}' /proc/1/status 2>/dev/null" 2>/dev/null || echo 0)

  awk -v cur="${MEM_CURRENT:-0}" -v max="${MEM_MAX:-0}" -v rss="${RSS_KB:-0}" 'BEGIN {
    cur_mi = cur / 1024 / 1024
    max_mi = (max == "max" || max == 0) ? -1 : max / 1024 / 1024
    rss_mi = rss / 1024
    pct = (max_mi > 0) ? (cur_mi / max_mi) * 100 : 0
    if (max_mi > 0) {
      printf "cgroup memory.current: %.1fMi / %.1fMi (~%.1f%% vom Limit)\n", cur_mi, max_mi, pct
    } else {
      printf "cgroup memory.current: %.1fMi (Limit nicht lesbar)\n", cur_mi
    }
    printf "Java-Prozess RSS (/proc/1/status): %.1fMi\n", rss_mi
  }'

  # --- Effektive Heap-Groesse: bestaetigt, dass MaxRAMPercentage=75.0 im Pod-Cgroup greift ---
  echo
  echo "--- Effektive JVM-Heap-Sizing (container-aware, MaxRAMPercentage=75.0) ---"
  kubectl exec -n "${NAMESPACE}" "${POD}" -c hello-world -- \
    sh -c 'java -XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=75.0 -XX:+PrintFlagsFinal -version 2>/dev/null \
      | grep -E "MaxHeapSize|InitialHeapSize"' \
    | awk '{ printf "%-20s = %.1fMi\n", $2, $4/1024/1024 }' \
    || echo "nicht ermittelbar (java im Container nicht ausfuehrbar?)"

  # --- AOT & Startzeit aus den Container-Logs ---
  echo
  echo "--- AOT-Verarbeitung & Startzeit (aus Pod-Logs) ---"
  AOT_LINE=$(kubectl logs -n "${NAMESPACE}" "${POD}" -c hello-world 2>/dev/null | grep -m1 "AOT-processed" || true)
  STARTED_LINE=$(kubectl logs -n "${NAMESPACE}" "${POD}" -c hello-world 2>/dev/null | grep -m1 -E "Started .* in [0-9.]+ seconds" || true)

  if [[ -n "${AOT_LINE}" ]]; then
    echo "AOT aktiv: ${AOT_LINE}"
  else
    echo "Kein 'AOT-processed' in den Logs gefunden (spring.aot.enabled evtl. nicht wirksam oder Logs bereits rotiert)."
  fi

  if [[ -n "${STARTED_LINE}" ]]; then
    echo "Startzeit: ${STARTED_LINE}"
  else
    echo "Keine Startzeit-Zeile in den Logs gefunden."
  fi
done
