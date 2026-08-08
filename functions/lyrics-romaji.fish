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

    set -l original_rows (string replace -a \n\n \n'[[BLANK_LINE]]'\n -- "$lyrics" | string split \n)
    set -l numbered_lyrics
    for index in (seq (count $original_rows))
        set -a numbered_lyrics (printf '%03d: %s' $index "$original_rows[$index]")
    end

    set -l prompt_lyrics (string join \n $numbered_lyrics)
    set -l prompt (string join \n \
        'Each source record below starts with a three-digit number and colon.' \
        'For every source record, output exactly one record in this format: NNN: romaji | English translation.' \
        'Romanize Japanese as Hepburn-style romaji and translate it into natural, faithful English.' \
        'Never split a source record, even at punctuation, and never omit repeated lines.' \
        'For an NNN: [[BLANK_LINE]] record, output NNN: [[BLANK_LINE]] exactly.' \
        'For lines containing only English, repeat the original text unchanged on both sides.' \
        'Do not add headings, explanations, markdown, or extra records.' \
        '' \
        'Lyrics:' \
        "$prompt_lyrics")
    set -l response (jq -n \
        --arg model 'gemma4:31b-cloud' \
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

    set -l rows (string split \n -- "$romaji" | string match -rv '^$')
    if test (count $rows) -ne (count $original_rows)
        echo "Ollama changed the lyric line count: expected "(count $original_rows)", received "(count $rows) >&2
        return 1
    end

    for index in (seq (count $rows))
        set -l prefix (printf '%03d:' $index)
        if not string match -q "$prefix*" -- "$rows[$index]"
            echo "Ollama changed lyric record "(printf '%03d' $index) >&2
            return 1
        end

        set rows[$index] (string replace -r '^[0-9]{3}:\s*' '' -- "$rows[$index]")
    end

    set -l original_width (string length --visible 'Original')
    set -l romaji_width (string length --visible 'Romaji')

    for index in (seq (count $original_rows))
        set -l original_line $original_rows[$index]
        set -l row $rows[$index]
        if test "$original_line" = '[[BLANK_LINE]]'
            if test "$row" != '[[BLANK_LINE]]'
                echo "Ollama changed the lyric stanza breaks" >&2
                return 1
            end
            continue
        end

        if test "$row" = '[[BLANK_LINE]]'
            echo "Ollama changed the lyric stanza breaks" >&2
            return 1
        end

        set -l columns (string split -m1 '|' -- "$row")
        set -l width (string length --visible (string trim -- "$columns[1]"))
        if test $width -gt $romaji_width
            set romaji_width $width
        end

        set width (string length --visible (string trim -- "$original_line"))
        if test $width -gt $original_width
            set original_width $width
        end
    end

    begin
        printf '🎵 %s\n♪ %s\n\n' "$artist" "$track"
        printf '%s │ %s │ %s\n' \
            (string pad -w $original_width --right 'Original') \
            (string pad -w $romaji_width --right 'Romaji') \
            'English'

        for index in (seq (count $original_rows))
            set -l original_line $original_rows[$index]
            set -l row $rows[$index]
            if test "$original_line" = '[[BLANK_LINE]]'
                printf '\n'
                continue
            end

            set -l columns (string split -m1 '|' -- "$row")
            printf '%s │ %s │ %s\n' \
                (string pad -w $original_width --right (string trim -- "$original_line")) \
                (string pad -w $romaji_width --right (string trim -- "$columns[1]")) \
                (string trim -- "$columns[2]")
        end
    end | gum pager
end
