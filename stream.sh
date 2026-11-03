#!/bin/bash
set -u

REPO="${GITHUB_REPOSITORY}"
WORKFLOW_FILE="main.yml"
API_BASE="https://api.github.com/repos/${REPO}/actions/workflows/${WORKFLOW_FILE}/runs"

KICK_CHANNEL="${KICK_CHANNEL:-SXB}"
RESTREAM_KEY="${RESTREAM_KEY:?RESTREAM_KEY required}"
RESTREAM_URL="${RESTREAM_URL:-rtmp://live.restream.io/live}"
PLACEHOLDER_IMAGE="${PLACEHOLDER_IMAGE:-placeholder.png}"

# إعدادات التوقيت (السلسلة اللانهائية)
MAX_STREAM_SEC=19800      # 330 دقيقة = 5.5 ساعات (وقت خروج الرن)
TRIGGER_AT_SEC=18000      # 300 دقيقة = 5 ساعات (وقت إطلاق الرن التالي)
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

# إذا كان هذا الرن (يدوي أو كرون) وهناك سلسلة نشطة، انسحب فوراً لمنع التكرار
if [ "${TRIGGER_TYPE}" != "repository_dispatch" ]; then
    INITIAL=$(get_active_runs)
    if [ "$(count_chain "$INITIAL")" -gt 0 ]; then
        echo "[$(date)] هناك سلسلة نشطة بالفعل. سيتم الإلغاء لتجنب التداخل."
        exit 0
    fi
fi

# انتظر حتى يخلو الجو من الرن السابق (لحظة التسليم)
echo "[$(date)] جاري فحص الرن السابق..."
while true; do
    ACTIVE=$(get_active_runs)
    if [ -z "$ACTIVE" ]; then
        echo "[$(date)] لا يوجد رن نشط. بدء البث الآن."
        break
    fi
    sleep 3
done

# ==========================================
# 2. منطق البث والإطلاق
# ==========================================
trigger_next() {
    echo "[$(date)] جاري إطلاق الرن التالي في الخلفية..."
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

# ⚡ دالة البث المباشر: فيديو نسخ أصلي + صوت معالج (نقي وواضح)
run_stream() {
    local duration="$1" url="$2"
    timeout "${duration}s" ffmpeg -y -hide_banner -loglevel warning \
        -reconnect 1 -reconnect_streamed 1 -reconnect_at_eof 1 -reconnect_delay_max 2 \
        -rw_timeout 10000000 \
        -i "$url" \
        -map 0:v:0 -map 0:a:0? \
        -c:v copy \
        -c:a aac -b:a 192k -ar 48000 -ac 2 \
        -af "highpass=f=90,loudnorm=I=-16:TP=-1.5:LRA=11" \
        -f flv "${RESTREAM_URL}/${RESTREAM_KEY}" 2>/dev/null &
    echo $!
}

# دالة شاشة الانتظار: تحديث التردد إلى 48000Hz
run_placeholder() {
    local duration="$1"
    if [ ! -f "$PLACEHOLDER_IMAGE" ]; then
        echo ""
        return 1
    fi
    timeout "${duration}s" ffmpeg -y -hide_banner -loglevel error \
        -re -loop 1 -framerate 30 -i "$PLACEHOLDER_IMAGE" \
        -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
        -c:v libx264 -preset veryfast -tune stillimage -pix_fmt yuv420p \
        -g 60 -b:v 2500k -maxrate 2500k -bufsize 5000k \
        -c:a aac -b:a 128k -ar 48000 -ac 2 \
        -shortest -f flv "${RESTREAM_URL}/${RESTREAM_KEY}" 2>/dev/null &
    echo $!
}

TRIGGER_ATTEMPTED=0
TRIGGER_PID=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))

    # 1. الخروج عند الوصول للحد الأقصى (5.5 ساعات)
    if [ "$ELAPSED" -ge "$MAX_STREAM_SEC" ]; then
        echo "[$(date)] وصلنا للحد الأقصى (5.5 ساعات). إيقاف البث لهذا الرن وتسليم المهمة."
        break
    fi

    # 2. إطلاق الرن التالي عند الدقيقة 300 (5 ساعات)
    if [ "$TRIGGER_ATTEMPTED" -eq 0 ] && [ "$ELAPSED" -ge "$TRIGGER_AT_SEC" ]; then
        TRIGGER_ATTEMPTED=1
        trigger_next &
        TRIGGER_PID=$!
    fi

    # 3. تشغيل البث أو شاشة الانتظار
    REMAINING=$((MAX_STREAM_SEC - ELAPSED))
    STREAM_URL=$(yt-dlp -g --no-warnings "https://kick.com/${KICK_CHANNEL}" 2>/dev/null | head -n 1)

    if [ -z "$STREAM_URL" ]; then
        SEG=$(( REMAINING < 60 ? REMAINING : 60 ))
        echo "[$(date)] القناة غير متصلة. عرض شاشة الانتظار لـ ${SEG} ثانية."
        FF_PID=$(run_placeholder "$SEG") || FF_PID=""
    else
        echo "[$(date)] القناة متصلة. بدء النسخ المباشر مع تحسين الصوت (متبقي ${REMAINING} ثانية)."
        FF_PID=$(run_stream "$REMAINING" "$STREAM_URL")
    fi

    if [ -z "$FF_PID" ]; then
        echo "[$(date)] فشل تشغيل ffmpeg. إعادة المحاولة بعد 30 ثانية."
        sleep 30
        continue
    fi

    # مراقبة البث
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

# تأكيد إطلاق الرن التالي قبل الخروج النهائي
if [ -n "$TRIGGER_PID" ]; then
    wait "$TRIGGER_PID" 2>/dev/null || true
fi

if [ "$TRIGGER_ATTEMPTED" -eq 0 ]; then
    trigger_next || echo "[$(date)] فشل إطلاق الرن الأخير! النظام سيعتمد على الكرون."
fi

exit 0
