function lyrics
    if test (count $argv) -eq 0
        echo "Usage: lyrics <search>"
        return 1
    end

    set -l query (string join " " $argv)
    set -l json (curl -fsSG 'https://lrclib.net/api/search' \
        --data-urlencode "q=$query")

    set -l selection (
        echo $json |
        jq -r '.[] | "\(.artistName) — \(.trackName)"' |
        gum choose
    )

    or return

    set -l artist (string split " — " $selection)[1]
    set -l track  (string split " — " $selection)[2]

    echo $json |
    jq -r --arg a "$artist" --arg t "$track" '
        .[]
        | select(.artistName == $a and .trackName == $t)
        | "🎵 \(.artistName)\n♪ \(.trackName)\n\n\(.plainLyrics // "No lyrics available.")"
    ' |
    gum pager
end
