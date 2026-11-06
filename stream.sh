#!/bin/bash
set +m
set -uo pipefail

# ═══════════════════════════════════════════════════════════════
#  Single Streamer Relay — V16 (Ultimate HTML Frame Overlay)
# ═══════════════════════════════════════════════════════════════

STREAMER_EN="${STREAMER_EN:-SXB}"
STREAMER_AR="${STREAMER_AR:-شونق بونق}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

WORKDIR="/tmp/standby_relay"
FIFO="/tmp/relay.ts"
KEEPER_READY="/tmp/relay_keeper.ready"
mkdir -p "$WORKDIR"
export STREAMER_EN STREAMER_AR WORKDIR

# ───────────────────────────────────────────────
#  Standby & Frame Generation
# ───────────────────────────────────────────────
generate_standby() {
    echo "🎨 Generating animated standby screen for $STREAMER_EN ($STREAMER_AR)..."
    mkdir -p ~/.fonts
    [ ! -s ~/.fonts/Cairo-var.ttf ] && curl -sL --max-time 30 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/cairo/Cairo%5Bslnt%2Cwght%5D.ttf" \
        -o ~/.fonts/Cairo-var.ttf || true
    [ ! -s ~/.fonts/Orbitron-var.ttf ] && curl -sL --max-time 30 \
        "https://raw.githubusercontent.com/google/fonts/main/ofl/orbitron/Orbitron%5Bwght%5D.ttf" \
        -o ~/.fonts/Orbitron-var.ttf || true
    fc-cache -f >/dev/null 2>&1 || true

    cat > /tmp/make_ui.py <<'PYEOF'
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 1920, 1080
WORKDIR = os.environ.get("WORKDIR", "/tmp/standby_relay")
NAME_EN = os.environ.get("STREAMER_EN", "STREAMER").upper()
NAME_AR = os.environ.get("STREAMER_AR", "جاري الانتظار")

def font(path, size, weight=700):
    try:
        f = ImageFont.truetype(path, size)
        axes = f.get_variation_axes()
        if len(axes) == 1:
            f.set_variation_by_axes([weight])
        elif len(axes) == 2:
            f.set_variation_by_axes([0, weight])
        return f
    except Exception:
        return ImageFont.load_default()

bg = Image.new("RGB", (W, H), (10, 2, 20))
d = ImageDraw.Draw(bg)
for y in range(H):
    t = y / H
    d.line([(0, y), (W, y)], fill=(int(10+20*t), int(2+8*t), int(20+30*t)))

grid = Image.new("RGBA", (W, H), (0,0,0,0))
gd = ImageDraw.Draw(grid)
for x in range(0, W, 100):
    gd.line([(x,0),(x,H)], fill=(166,77,255,15), width=1)
for y in range(0, H, 100):
    gd.line([(0,y),(W,y)], fill=(166,77,255,15), width=1)
bg = Image.alpha_composite(bg.convert("RGBA"), grid)

f_en = font(os.path.expanduser("~/.fonts/Orbitron-var.ttf"), 140, 900)
t_img = Image.new("RGBA", (W, H), (0,0,0,0))
ImageDraw.Draw(t_img).text((W//2, 400), NAME_EN,
                            font=f_en, fill=(212,179,255,255), anchor="mm")
bg = Image.alpha_composite(bg, t_img.filter(ImageFilter.GaussianBlur(20)))
bg = Image.alpha_composite(bg, t_img)

f_ar = font(os.path.expanduser("~/.fonts/Cairo-var.ttf"), 80, 700)
ImageDraw.Draw(bg).text((W//2, 530), NAME_AR,
                        font=f_ar, fill=(255,255,255,255), anchor="mm")

bg.convert("RGB").save(os.path.join(WORKDIR, "bg.png"), "PNG")
PYEOF

    WORKDIR="$WORKDIR" python3 /tmp/make_ui.py || return 1

    echo "🎬 Rendering motion video (60s loop)..."
    ffmpeg -y -hide_banner -loglevel warning \
        -loop 1 -framerate 60 -i "$WORKDIR/bg.png" \
        -f lavfi -i "anoisesrc=c=brown:r=44100:a=0.05" \
        -filter_complex "[0:v]scale=3840:2160,zoompan=z='min(zoom+0.0005,1.2)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=3600:s=1920x1080:fps=60[v0]; \
                         [v0]drawtext=fontfile=$HOME/.fonts/Orbitron-var.ttf:text='%{pts\\:hms}':x=w-tw-60:y=60:fontsize=60:fontcolor=white@0.8[v1]; \
                         [v1]drawtext=fontfile=$HOME/.fonts/Cairo-var.ttf:text='جاري انتظار بث الستريمر...':x=w-mod(t*150\\,w+tw):y=h-150:fontsize=60:fontcolor=white[v]" \
        -map "[v]" -map 1:a \
        -t 60 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 120 -r 60 \
        -c:a aac -b:a 128k -ar 44100 -ac 2 -shortest \
        -f mpegts "$WORKDIR/standby.ts" || return 1
        
    echo "✅ Animated Standby ready"
    return 0
}

generate_frame_bg() {
    echo "🖼️ Generating Live Frame Overlay using HTML & Playwright..."
    
    # 1. حفظ التصميم (HTML) اللي عجبك
    cat > /tmp/frame.html <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ar" dir="rtl">
<head>
    <meta charset="UTF-8">
    <link href="https://fonts.googleapis.com/css2?family=Cairo:wght@700;900&display=swap" rel="stylesheet">
    <style>
        body { background: transparent; margin: 0; padding: 0; overflow: hidden; font-family: 'Cairo', sans-serif; }
        .stream-container { position: relative; width: 1920px; height: 1080px; background: transparent; overflow: hidden; }
        .inner-border { position: absolute; inset: 0; border: 6px solid #990000; pointer-events: none; z-index: 10; box-shadow: inset 0 0 30px rgba(255, 0, 0, 0.6); }
        .top-bar { position: absolute; top: 0; left: 0; right: 0; height: 15%; background: linear-gradient(to bottom, #000000 0%, #1a0000 100%); border-bottom: 4px solid #ff0000; display: flex; justify-content: center; align-items: center; z-index: 20; clip-path: polygon(0 0, 100% 0, 100% 85%, 95% 100%, 5% 100%, 0 85%); }
        .title-text { font-size: 64px; font-weight: 900; color: #fff; display: flex; gap: 15px; letter-spacing: 1px; text-shadow: 2px 2px 0 #000, 0 0 15px rgba(255,0,0,0.8); }
        .title-text span { color: #ff0000; text-shadow: 2px 2px 0 #000, 0 0 20px #ff0000; }
        .prison-bars { position: absolute; left: 2%; top: 20%; height: 60%; width: 80px; display: flex; justify-content: space-between; opacity: 0.7; }
        .prison-bars::before, .prison-bars::after, .prison-bars div { content: ''; width: 4px; height: 100%; background: linear-gradient(to bottom, #555, #222); border-radius: 2px; }
        .handcuffs { position: absolute; right: 3%; top: 25%; width: 80px; height: 40px; display: flex; align-items: center; justify-content: space-between; opacity: 0.8; }
        .cuff { width: 35px; height: 35px; border: 5px solid #888; border-radius: 50%; box-shadow: inset 0 0 5px #000; }
        .cuff-chain { width: 10px; height: 4px; background: #888; }
        .bottom-bar { position: absolute; bottom: 0; left: 0; right: 0; height: 10%; background: #000; border-top: 4px solid #ff0000; z-index: 20; clip-path: polygon(5% 0, 95% 0, 100% 100%, 0 100%); }
        .corner-accent { position: absolute; bottom: 10%; width: 40px; height: 40px; border: 4px solid #ff0000; z-index: 15; }
        .corner-accent.left { left: 0; border-right: none; border-top: none; }
        .corner-accent.right { right: 0; border-left: none; border-top: none; }
    </style>
</head>
<body>
    <div class="stream-container">
        <div class="inner-border"></div>
        <div class="corner-accent left"></div>
        <div class="corner-accent right"></div>
        <div class="top-bar">
            <div class="prison-bars"><div></div><div></div></div>
            <div class="title-text">بث السجن <span>30 يوم!</span></div>
            <div class="handcuffs"><div class="cuff"></div><div class="cuff-chain"></div><div class="cuff"></div></div>
        </div>
        <div class="bottom-bar"></div>
    </div>
</body>
</html>
HTMLEOF

    # 2. توليد الصورة الشفافة من HTML + توليد النص المتحرك
    cat > /tmp/make_frame.py <<'PYEOF'
import os
from playwright.sync_api import sync_playwright
from PIL import Image, ImageDraw, ImageFont

WORKDIR = os.environ.get("WORKDIR", "/tmp/standby_relay")

# أ) تحويل التصميم لصورة شفافة
print("Rendering HTML frame via Playwright...")
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={'width': 1920, 'height': 1080})
    page.goto("file:///tmp/frame.html")
    page.screenshot(path=os.path.join(WORKDIR, "frame_bg.png"), omit_background=True)
    browser.close()

# ب) توليد صورة النص المتحرك
print("Generating marquee text...")
font_path = os.path.expanduser("~/.fonts/Cairo-var.ttf")
font = ImageFont.truetype(font_path, 45)
text = "تكبيس وفولو يارجال  |  والبث مايوقف!  |  تكبيس وفولو يارجال  |  والبث مايوقف!  |  "

dummy = Image.new("RGBA", (1, 1))
d = ImageDraw.Draw(dummy)
bbox = d.textbbox((0, 0), text, font=font, direction="rtl")
text_width = bbox[2] - bbox[0]

img = Image.new("RGBA", (text_width + 200, 80), (0,0,0,0))
d = ImageDraw.Draw(img)
d.text((100, 10), text, font=font, fill=(255,255,255,255), direction="rtl")
img.save(os.path.join(WORKDIR, "marquee.png"))
PYEOF

    WORKDIR="$WORKDIR" python3 /tmp/make_frame.py || return 1
    echo "✅ Live Frame & Marquee ready"
}

if [ "${PREPARE_ONLY:-0}" = "1" ]; then
    generate_standby
    generate_frame_bg
    exit $?
fi

RESTREAM_KEY="${RESTREAM_KEY:-}"
[ -z "$RESTREAM_KEY" ] && { echo "❌ RESTREAM_KEY empty"; exit 1; }
RESTREAM_URL="rtmp://live.restream.io/live/$RESTREAM_KEY"

[ ! -f "$WORKDIR/standby.ts" ] && { generate_standby || exit 1; }
[ ! -f "$WORKDIR/frame_bg.png" ] && { generate_frame_bg || exit 1; }

# ───────────────────────────────────────────────
#  Process management
# ───────────────────────────────────────────────
OUT=""; PROD=""; KEEPER=""
MODE="STANDBY"
OFFLINE_START=0
OUT_STARTED=0; PROD_STARTED=0
OUT_PREV_FRAME=""; PROD_PREV_FRAME=""
OUT_STALL=0; PROD_STALL=0
LAST_SCAN=0

stop_group() {
    local pid="${1:-}"
    [ -z "$pid" ] && return 0
    kill -TERM -- "-$pid" 2>/dev/null || true
    local i=0
    while [ $i -lt 20 ]; do
        kill -0 -- "-$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || true; return 0; }
        sleep 0.15; i=$((i+1))
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

stop_output() {
    [ -z "$OUT" ] && return 0
    kill -TERM "$OUT" 2>/dev/null || true
    local i=0
    while [ $i -lt 20 ]; do
        kill -0 "$OUT" 2>/dev/null || { wait "$OUT" 2>/dev/null || true; OUT=""; return 0; }
        sleep 0.15; i=$((i+1))
    done
    kill -KILL "$OUT" 2>/dev/null || true
    wait "$OUT" 2>/dev/null || true
    OUT=""
}

stop_producer() { [ -n "$PROD" ] && { stop_group "$PROD"; PROD=""; }; }
stop_keeper()   { [ -n "$KEEPER" ] && { stop_group "$KEEPER"; KEEPER=""; }; }

cleanup() {
    trap - EXIT INT TERM
    stop_producer; stop_output; stop_keeper
    rm -f "$KEEPER_READY" "$FIFO"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

setup_fifo() { rm -f "$FIFO" "$KEEPER_READY"; mkfifo "$FIFO"; }

start_keeper() {
    rm -f "$KEEPER_READY"
    setsid bash -c 'exec 3>"$1" || exit 1; : > "$2"; exec sleep infinity' \
        _ "$FIFO" "$KEEPER_READY" >/dev/null 2>&1 &
    KEEPER=$!
    local i=0
    while [ $i -lt 100 ]; do
        [ -f "$KEEPER_READY" ] && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}

get_frame() {
    [ -f "$1" ] || return 0
    tail -n 30 "$1" 2>/dev/null | awk -F= '$1=="frame" {v=$2} END {print v}'
}

start_output_with_retry() {
    local max_attempts=10
    local i=0
    while [ $i -lt $max_attempts ]; do
        i=$((i+1))
        rm -f /tmp/out.prog
        ffmpeg -y -hide_banner -loglevel warning -nostdin \
            -thread_queue_size 512 \
            -fflags +genpts+discardcorrupt \
            -f mpegts -i "$FIFO" \
            -map 0:v:0 -map 0:a:0? -c:v copy -c:a copy \
            -max_muxing_queue_size 4096 \
            -flvflags no_duration_filesize \
            -rtmp_live live \
            -progress /tmp/out.prog -stats_period 1 \
            -f flv "$RESTREAM_URL" >/tmp/out.log 2>&1 &
        OUT=$!
        OUT_STARTED=$(date +%s)
        OUT_PREV_FRAME=""; OUT_STALL=0
        sleep 3
        if kill -0 "$OUT" 2>/dev/null; then
            echo "✅ Output connected"
            return 0
        fi
        echo "⚠️ Output rejected, retry..."
        wait "$OUT" 2>/dev/null || true
        OUT=""
        sleep 2
    done
    echo "❌ Output failed"
    return 1
}

wait_prod_ready() {
    local i=0
    while [ $i -lt 50 ]; do
        kill -0 "$PROD" 2>/dev/null || return 1
        local f=$(get_frame /tmp/prod.prog)
        [[ "$f" =~ ^[0-9]+$ ]] && [ "$f" -gt 0 ] && return 0
        sleep 0.5; i=$((i+1))
    done
    return 1
}

start_prod_standby() {
    rm -f /tmp/prod.prog
    setsid ffmpeg -y -hide_banner -loglevel warning -nostdin \
        -re -stream_loop -1 -i "$WORKDIR/standby.ts" \
        -c copy -mpegts_flags +resend_headers \
        -progress /tmp/prod.prog -stats_period 1 \
        -f mpegts "$FIFO" >/tmp/prod.log 2>&1 &
    PROD=$!
    PROD_STARTED=$(date +%s); PROD_PREV_FRAME=""; PROD_STALL=0
    if wait_prod_ready; then
        MODE="STANDBY"; echo "✅ STANDBY active"; return 0
    fi
    stop_producer
    return 1
}

start_prod_live() {
    rm -f /tmp/prod.prog
    echo "🚀 Starting LIVE with Frame Overlay..."
    
    # دمج البث مع الإطار الصوري + النص المتحرك (marquee.png)
    setsid bash -c '
        streamlink --http-header "User-Agent='"$UA"'" "https://kick.com/'"$STREAMER_EN"'" best --stdout 2>/dev/null | \
        ffmpeg -y -hide_banner -loglevel warning -nostdin \
            -thread_queue_size 512 \
            -fflags +genpts+discardcorrupt \
            -i pipe:0 \
            -loop 1 -i "'"$WORKDIR"'/frame_bg.png" \
            -loop 1 -i "'"$WORKDIR"'/marquee.png" \
            -filter_complex "\
                [0:v]fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2[v0]; \
                [v0][1:v]overlay=0:0[bg]; \
                [bg][2:v]overlay=x='"'"'W-mod(t*200\,W+overlay_w)'"'"':y=H-95[out]" \
            -map "[out]" -map 0:a? \
            -c:v libx264 -preset ultrafast -tune zerolatency -crf 24 -pix_fmt yuv420p \
            -c:a aac -b:a 160k -ar 44100 -ac 2 \
            -max_muxing_queue_size 4096 \
            -mpegts_flags +resend_headers \
            -progress /tmp/prod.prog -stats_period 1 \
            -f mpegts "'"$FIFO"'" >/tmp/prod.log 2>&1
    ' >/dev/null 2>&1 &
    
    PROD=$!
    PROD_STARTED=$(date +%s); PROD_PREV_FRAME=""; PROD_STALL=0
    if wait_prod_ready; then
        MODE="LIVE"; echo "✅ LIVE: $STREAMER_EN (With Frame)"; return 0
    fi
    stop_producer
    return 1
}

is_streamer_live() {
    URL=$(timeout 8 streamlink --http-header "User-Agent=$UA" \
        "https://kick.com/$STREAMER_EN" best --stream-url 2>/dev/null | grep -m1 "^http")
    [ -n "$URL" ] && return 0 || return 1
}

restart_output_chain() {
    echo "♻️ Full chain restart"
    stop_producer; stop_output; stop_keeper
    setup_fifo
    start_output_with_retry || { echo "❌ FATAL: cannot connect"; exit 1; }
    start_keeper || { echo "❌ FATAL: keeper failed"; exit 1; }
    
    if is_streamer_live; then
        OFFLINE_START=0
        start_prod_live || start_prod_standby
    else
        OFFLINE_START=$(date +%s)
        start_prod_standby
    fi
    LAST_SCAN=$(date +%s)
}

# ───────────────────────────────────────────────
#  Schedule next run (5h15m from now)
# ───────────────────────────────────────────────
if [ -n "${MY_RUN_ID:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
    echo "📅 Scheduling next run in 5h15m"
    setsid nohup bash -c "
        sleep 18900
        for i in 1 2 3 4 5; do
            if gh workflow run main.yml --ref '${GITHUB_REF_NAME:-main}' -f parent_run_id=$MY_RUN_ID; then
                echo \"✅ Next run dispatched\"
                exit 0
            fi
            sleep 60
        done
    " >/tmp/sched.log 2>&1 < /dev/null &
fi

# ───────────────────────────────────────────────
#  Boot
# ───────────────────────────────────────────────
echo "🚀 Single Streamer Relay V16 starting..."
setup_fifo
start_output_with_retry || { echo "❌ FATAL: initial connect failed"; exit 1; }
start_keeper || { echo "❌ FATAL: keeper failed"; exit 1; }

if is_streamer_live; then
    OFFLINE_START=0
    start_prod_live || start_prod_standby
else
    OFFLINE_START=$(date +%s)
    start_prod_standby
fi
LAST_SCAN=$(date +%s)

# ───────────────────────────────────────────────
#  Main loop (Watchdog + 20m Timeout)
# ───────────────────────────────────────────────
while true; do
    NOW=$(date +%s)

    if ! kill -0 "$OUT" 2>/dev/null; then
        echo "⚠️ Output died"
        restart_output_chain
        continue
    fi

    if ! kill -0 "$PROD" 2>/dev/null; then
        echo "⚠️ Producer died"
        stop_producer
        if is_streamer_live; then
            OFFLINE_START=0
            start_prod_live || start_prod_standby
        else
            [ "$OFFLINE_START" -eq 0 ] && OFFLINE_START=$NOW
            start_prod_standby
        fi
        continue
    fi

    # Watchdog: Output stall
    if [ $((NOW - OUT_STARTED)) -ge 20 ]; then
        F=$(get_frame /tmp/out.prog)
        MT=$(stat -c %Y /tmp/out.prog 2>/dev/null || echo $OUT_STARTED)
        if [ $((NOW - MT)) -ge 20 ]; then OUT_STALL=20; 
        elif [[ "$F" =~ ^[0-9]+$ ]]; then
            if [ -n "$OUT_PREV_FRAME" ] && [ "$F" -le "$OUT_PREV_FRAME" ]; then OUT_STALL=$((OUT_STALL + 1)); else OUT_STALL=0; fi
            OUT_PREV_FRAME="$F"
        fi
        if [ "$OUT_STALL" -ge 20 ]; then
            echo "⚠️ Output stalled"
            restart_output_chain
            continue
        fi
    fi

    # Watchdog: Producer stall
    if [ $((NOW - PROD_STARTED)) -ge 15 ]; then
        F=$(get_frame /tmp/prod.prog)
        MT=$(stat -c %Y /tmp/prod.prog 2>/dev/null || echo $PROD_STARTED)
        if [ $((NOW - MT)) -ge 15 ]; then PROD_STALL=15;
        elif [[ "$F" =~ ^[0-9]+$ ]]; then
            if [ -n "$PROD_PREV_FRAME" ] && [ "$F" -le "$PROD_PREV_FRAME" ]; then PROD_STALL=$((PROD_STALL + 1)); else PROD_STALL=0; fi
            PROD_PREV_FRAME="$F"
        fi
        if [ "$PROD_STALL" -ge 15 ]; then
            echo "⚠️ Producer stalled"
            stop_producer
            if is_streamer_live; then OFFLINE_START=0; start_prod_live || start_prod_standby
            else [ "$OFFLINE_START" -eq 0 ] && OFFLINE_START=$NOW; start_prod_standby; fi
            continue
        fi
    fi

    if [ $((NOW - LAST_SCAN)) -ge 15 ]; then
        LAST_SCAN=$NOW
        if is_streamer_live; then
            OFFLINE_START=0
            if [ "$MODE" != "LIVE" ]; then
                echo "🔀 Streamer is LIVE. Switching from STANDBY."
                stop_producer
                start_prod_live || start_prod_standby
            fi
        else
            if [ "$MODE" = "LIVE" ]; then
                echo "📴 Streamer went OFFLINE. Switching to STANDBY."
                stop_producer
                start_prod_standby
                OFFLINE_START=$NOW
            fi
            
            if [ "$OFFLINE_START" -gt 0 ]; then
                OFFLINE_DURATION=$((NOW - OFFLINE_START))
                if [ "$OFFLINE_DURATION" -ge 1200 ]; then
                    echo "🛑 Streamer offline for 20 minutes. Terminating job to save minutes."
                    exit 0
                fi
            fi
        fi
    fi

    sleep 1
done
