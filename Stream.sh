#!/bin/bash
set -u

REPO="${GITHUB_REPOSITORY}"
WORKFLOW_FILE="main.yml"
API_BASE="https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW_FILE}/runs"

KICK_CHANNEL="${KICK_CHANNEL:-SXB}"
RESTREAM_KEY="${RESTREAM_KEY:?RESTREAM_KEY required}"
RESTREAM_URL="${RESTREAM_URL:-rtmp://live.restream.io/live}"
PLACEHOLDER_IMAGE="${PLACEHOLDER_IMAGE:-placeholder.png}"

MAX_STREAM_SEC=19200      # 320 دقيقة (وقت الخروج)
TRIGGER_AT_SEC=18000      # 300 دقيقة (وقت إطلاق الرن التالي)
START_TS=$(date +%s)

# ==========================================
# 1. منطق الانتظار (Watchdog) 
# ==========================================
get_active_runs() {
    curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
              -H "Accept: application/vnd.github+json" \
              "${API_BASE}?per_page=30" | \
    jq -r --arg self "$GITHUB_RUN_ID" \
      '.workflow_runs[]? | select(.id != ($self|tonumber)) | select(.status == "in_progress" or .status == "queued" or .status == "waiting") | "\(.id):\(.event):\(.status)"' \
      2>/dev/null || true
}

count_chain() {
    echo "$1" | grep ":repository_dispatch:" | wc -l | tr -d ' '
}

# إذا كان هذا الرن (Cron أو يدوي) وهناك سلسلة نشطة، انسحب فوراً لتجنب التداخل
if [ "${TRIGGER_TYPE}" != "repository_dispatch" ]; then
    INITIAL=$(get_active_runs)
    if [ "$(count_chain "$INITIAL")" -gt 0 ]; then
        echo "[$(date)] هناك سلسلة نشطة بالفعل. سيتم الإلغاء لتجنب التكرار."
        exit 0
    fi
fi

# انتظر حتى يخلو الجو من أي رن آخر
echo "[$(date)] جاري فحص الرنات السابقة..."
while true; do
    ACTIVE=$(get_active_runs)
    if [ -z "$ACTIVE" ]; then
        echo "[$(date)] لا يوجد رن نشط. بدء البث الآن."
        break
    fi
    sleep 3
done

# ==========================================
# 2. منطق البث (Streaming)
# ==========================================
trigger_next() {
    echo "[$(date)] جاري إطلاق الرن التالي..."
    for attempt in $(seq 1 10); do
        CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/${REPO}/dispatches" \
            -d "{\"event_type\":\"chain-trigger\",\"client_payload\":{\"parent_run\":\"${GITHUB_RUN_ID}\"}}")
        if [ "$CODE" = "204" ]; then
            echo "[$(date)] تم إطلاق الرن التالي بنجاح."
            return 0
        fi
        echo "[$(date)] فشل الإطلاق (HTTP=$CODE). محاولة $attempt..."
        sleep 10
    done
    return 1
}

run_stream() {
    local duration="$1" url="$2"
    timeout "${duration}s" ffmpeg -y -hide_banner -loglevel warning \
        -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_delay_max 2 \
        -rw_timeout 10000000 \
        -i "$url" \
        -c copy \
        -f flv "${RESTREAM_URL}/${RESTREAM_KEY}" 2>/dev/null &
    echo $!
}

run_placeholder() {
    local duration="$1"
    if [ ! -f "$PLACEHOLDER_IMAGE" ]; then
        echo ""
        return 1
    fi
    timeout "${duration}s" ffmpeg -y -hide_banner -loglevel error \
        -re -loop 1 -framerate 30 -i "$PLACEHOLDER_IMAGE" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
        -c:v libx264 -preset veryfast -tune stillimage -pix_fmt yuv420p \
        -g 60 -b:v 2500k -maxrate 2500k -bufsize 5000k \
        -c:a aac -b:a 128k -ar 44100 \
        -shortest -f flv "${RESTREAM_URL}/${RESTREAM_KEY}" 2>/dev/null &
    echo $!
}

TRIGGER_ATTEMPTED=0
TRIGGER_PID=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))

    # الخروج عند الوصول للحد الأقصى
    if [ "$ELAPSED" -ge "$MAX_STREAM_SEC" ]; then
        echo "[$(date)] وصلنا للحد الأقصى. إيقاف البث."
        break
    fi

    # إطلاق الرن التالي في الدقيقة 300
    if [ "$TRIGGER_ATTEMPTED" -eq 0 ] && [ "$ELAPSED" -ge "$TRIGGER_AT_SEC" ]; then
        TRIGGER_ATTEMPTED=1
        trigger_next &
        TRIGGER_PID=$!
    fi

    REMAINING=$((MAX_STREAM_SEC - ELAPSED))
    STREAM_URL=$(yt-dlp -g --no-warnings "https://kick.com/${KICK_CHANNEL}" 2>/dev/null | head -n 1)

    if [ -z "$STREAM_URL" ]; then
        SEG=$(( REMAINING < 60 ? REMAINING : 60 ))
        echo "[$(date)] القناة غير متصلة. عرض شاشة الانتظار لـ ${SEG} ثانية."
        FF_PID=$(run_placeholder "$SEG") || FF_PID=""
    else
        echo "[$(date)] القناة متصلة. بدء النسخ المباشر (متبقي ${REMAINING} ثانية)."
        FF_PID=$(run_stream "$REMAINING" "$STREAM_URL")
    fi

    if [ -z "$FF_PID" ]; then
        echo "[$(date)] فشل تشغيل ffmpeg. إعادة المحاولة بعد 30 ثانية."
        sleep 30
        continue
    fi

    # مراقبة ffmpeg
    while kill -0 "$FF_PID" 2>/dev/null; do
        NOW=$(date +%s)
        if [ $((NOW - START_TS)) -ge "$MAX_STREAM_SEC" ]; then
            kill "$FF_PID" 2>/dev/null || true
            break
        fi
        sleep 5
    done
    wait "$FF_PID" 2>/dev/null || true

    NOW=$(date +%s)
    if [ $((NOW - START_TS)) -ge "$MAX_STREAM_SEC" ]; then
        break
    fi
done

# في حال لم يتم إطلاق الرن التالي، أطلقه الآن
if [ -n "$TRIGGER_PID" ]; then
    wait "$TRIGGER_PID" 2>/dev/null || true
fi

if [ "$TRIGGER_ATTEMPTED" -eq 0 ]; then
    trigger_next || echo "[$(date)] فشل إطلاق الرن الأخير!"
fi

exit 0
