function lyrics
    set -l query

    if test (count $argv) -eq 0
        set query (playerctl -p re.fossplant.songrec metadata --format '{{artist}} - {{title}}')
        or return 1
    else
        set query (string join " " $argv)
    end

    set -l json (curl -fsSG 'https://lrclib.net/api/search' \
        --data-urlencode "q=$query")

    set -l results (echo $json | jq 'unique_by([.artistName, .trackName])')
    set -l choices (echo $results | jq -r '.[] | "\(.artistName) — \(.trackName)"')
    if test (count $choices) -eq 0
        echo "No lyrics found for: $query" >&2
        return 1
    end

    set -l selection (
        printf '%s\n' $choices |
        gum choose
    )

    or return

    set -l artist (string split " — " $selection)[1]
    set -l track  (string split " — " $selection)[2]

    echo $results |
    jq -r --arg a "$artist" --arg t "$track" '
        .[]
        | select(.artistName == $a and .trackName == $t)
        | "🎵 \(.artistName)\n♪ \(.trackName)\n\n\(.plainLyrics // "No lyrics available.")"
    ' |
    gum pager
end
