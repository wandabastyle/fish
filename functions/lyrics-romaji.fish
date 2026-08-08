function lyrics-romaji
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

    set -l lyrics (echo $results | jq -r --arg a "$artist" --arg t "$track" '
        .[]
        | select(.artistName == $a and .trackName == $t)
        | .plainLyrics // empty
    ' | string collect)

    if test -z "$lyrics"
        echo "No plain lyrics available for: $artist - $track" >&2
        return 1
    end

    if not curl -fs --connect-timeout 1 --max-time 2 \
        'http://127.0.0.1:11434/api/tags' >/dev/null
        systemctl --user start ollama.service
        or begin
            echo "Failed to start ollama.service" >&2
            return 1
        end

        for _ in (seq 1 25)
            if curl -fs --connect-timeout 1 --max-time 2 \
                'http://127.0.0.1:11434/api/tags' >/dev/null
                break
            end

            sleep 0.2
        end

        if not curl -fs --connect-timeout 1 --max-time 2 \
            'http://127.0.0.1:11434/api/tags' >/dev/null
            echo "Ollama server did not start" >&2
            return 1
        end
    end

    systemctl --user restart ollama-stop.timer
    or begin
        echo "Failed to refresh ollama-stop.timer" >&2
        return 1
    end

    set -l prompt (string join \n \
        'Romanize the Japanese lyrics below into Hepburn-style romaji.' \
        'Preserve every line break, punctuation mark, and non-Japanese text exactly.' \
        'Do not translate, explain, add headings, omit lines, or invent text.' \
        'Output only the romanized lyrics.' \
        '' \
        'Lyrics:' \
        "$lyrics")
    set -l response (jq -n \
        --arg model 'qwen3.5:397b-cloud' \
        --arg prompt "$prompt" \
        '{model: $model, prompt: $prompt, stream: true, think: false, keep_alive: "10m", options: {temperature: 0}}' |
        curl -fsS --connect-timeout 5 --max-time 300 \
            -H 'Content-Type: application/json' \
            -d @- \
            'http://127.0.0.1:11434/api/generate')
    or begin
        echo "Failed to romanize lyrics with Ollama" >&2
        return 1
    end

    set -l romaji (echo $response | jq -j 'select(.response).response' | string collect)
    if test -z "$romaji"
        echo "Ollama returned no romanized lyrics" >&2
        return 1
    end

    printf '🎵 %s\n♪ %s\n\n%s\n' "$artist" "$track" "$romaji" | gum pager
end
