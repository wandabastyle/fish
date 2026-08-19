function lyrics-romaji
    function __lyrics_romaji_wrap_cell
        set -l value $argv[1]
        set -l max_width $argv[2]
        set -l line

        for character in (string split '' -- "$value")
            set -l candidate "$line$character"
            if test -n "$line"; and test (string length --visible -- "$candidate") -gt $max_width
                printf '%s\n' "$line"
                set line $character
            else
                set line $candidate
            end
        end

        if test -n "$line"
            printf '%s\n' "$line"
        end
    end

    set -l query
    set -l refresh false

    if test "$argv[1]" = '--refresh'
        set refresh true
        set -e argv[1]
    end

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

        for attempt in (seq 1 25)
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

    set -l original_rows (string split \n -- "$lyrics")
    set -l numbered_lyrics
    set -l source_numbers
    for index in (seq (count $original_rows))
        if test -n "$original_rows[$index]"
            set -a source_numbers $index
            set -a numbered_lyrics (printf '%03d: %s' $index "$original_rows[$index]")
        end
    end

    set -l cache_dir "$HOME/.config/fish/lyrics-romaji"
    set -l cache_key (string join \n 'lyrics-romaji-v1' 'gemma4:31b-cloud' "$lyrics" | sha256sum | string split ' ')[1]
    set -l cache_file "$cache_dir/$cache_key.json"
    set -l cache_hit false
    set -l romaji

    if test "$refresh" = false; and test -f "$cache_file"
        set romaji (jq -er --arg lyrics "$lyrics" '
            select(.schema == 1 and .lyrics == ($lyrics | split("\n")))
            | .translations
            | if type == "array" then . else error("translations must be an array") end
            | .[]
            | (.sourceLine | tostring | ("000" + .)[-3:]) as $source_line
            | "\($source_line): \(.romaji) | \(.english)"
        ' "$cache_file" | string collect)
        if test $status -eq 0; and test -n "$romaji"
            set cache_hit true
        end
    end

    if test "$cache_hit" = false
        set -l prompt_lyrics (string join \n $numbered_lyrics)
        set -l prompt (string join \n \
            'Each source record below starts with a three-digit number and colon.' \
            'For every source record, output exactly one record in this format: NNN: romaji | English translation.' \
            'Romanize Japanese as Hepburn-style romaji and translate it into natural, faithful English.' \
            'Never split a source record, even at punctuation, and never omit repeated lines.' \
            'For lines containing only English, repeat the original text unchanged on both sides.' \
            'Do not add headings, explanations, markdown, or extra records.' \
            '' \
            'Lyrics:' \
            "$prompt_lyrics")
        printf 'Romanizing lyrics...\n' >&2
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

        set romaji (echo $response | jq -j 'select(.response).response' | string collect)
    end

    if test -z "$romaji"
        echo "Ollama returned no romanized lyrics" >&2
        return 1
    end

    set -l rows (string split \n -- "$romaji" | string match -rv '^$')
    if test (count $rows) -ne (count $source_numbers)
        echo "Ollama changed the lyric line count: expected "(count $source_numbers)", received "(count $rows) >&2
        return 1
    end

    for index in (seq (count $rows))
        set -l prefix (printf '%03d:' $source_numbers[$index])
        if not string match -q "$prefix*" -- "$rows[$index]"
            echo "Ollama changed lyric record "(printf '%03d' $source_numbers[$index]) >&2
            return 1
        end

        set rows[$index] (string replace -r '^[0-9]{3}:\s*' '' -- "$rows[$index]")
    end

    if test "$cache_hit" = false
        command mkdir -p "$cache_dir"
        or begin
            echo "Failed to create lyric cache directory: $cache_dir" >&2
            return 1
        end

        set -l cache_tmp (mktemp "$cache_file.XXXXXX")
        or begin
            echo "Failed to create lyric cache file" >&2
            return 1
        end

        begin
            for index in (seq (count $rows))
                set -l columns (string split -m1 '|' -- "$rows[$index]")
                printf '%s\t%s\t%s\n' \
                    $source_numbers[$index] \
                    (string trim -- "$columns[1]") \
                    (string trim -- "$columns[2]")
            end
        end | jq -Rn \
            --arg artist "$artist" \
            --arg track "$track" \
            --arg lyrics "$lyrics" \
            '{
                schema: 1,
                artist: $artist,
                track: $track,
                lyrics: ($lyrics | split("\n")),
                translations: [
                    inputs
                    | split("\t")
                    | {
                        sourceLine: (.[0] | tonumber),
                        romaji: .[1],
                        english: .[2]
                    }
                ]
            }' >"$cache_tmp"
        or begin
            rm -f "$cache_tmp"
            echo "Failed to write lyric cache" >&2
            return 1
        end

        mv "$cache_tmp" "$cache_file"
        or begin
            rm -f "$cache_tmp"
            echo "Failed to save lyric cache" >&2
            return 1
        end
    end

    set -l max_column_width 50
    set -l original_width (string length --visible 'Original')
    set -l romaji_width (string length --visible 'Romaji')
    set -l row_index 1

    for index in (seq (count $original_rows))
        set -l original_line $original_rows[$index]
        if test -z "$original_line"
            continue
        end

        set -l row $rows[$row_index]
        set row_index (math $row_index + 1)

        set -l columns (string split -m1 '|' -- "$row")
        set -l width (string length --visible (string trim -- "$columns[1]"))
        if test $width -gt $max_column_width
            set width $max_column_width
        end
        if test $width -gt $romaji_width
            set romaji_width $width
        end

        set width (string length --visible (string trim -- "$original_line"))
        if test $width -gt $max_column_width
            set width $max_column_width
        end
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

        set row_index 1
        for index in (seq (count $original_rows))
            set -l original_line $original_rows[$index]
            if test -z "$original_line"
                printf '\n'
                continue
            end

            set -l row $rows[$row_index]
            set row_index (math $row_index + 1)
            set -l columns (string split -m1 '|' -- "$row")
            set -l original_wrapped (__lyrics_romaji_wrap_cell (string trim -- "$original_line") $original_width)
            set -l romaji_wrapped (__lyrics_romaji_wrap_cell (string trim -- "$columns[1]") $romaji_width)
            set -l english_wrapped (__lyrics_romaji_wrap_cell (string trim -- "$columns[2]") $max_column_width)

            if test (count $original_wrapped) -eq 0
                set original_wrapped ''
            end
            if test (count $romaji_wrapped) -eq 0
                set romaji_wrapped ''
            end
            if test (count $english_wrapped) -eq 0
                set english_wrapped ''
            end

            set -l wrapped_line_count (count $original_wrapped)
            if test (count $romaji_wrapped) -gt $wrapped_line_count
                set wrapped_line_count (count $romaji_wrapped)
            end
            if test (count $english_wrapped) -gt $wrapped_line_count
                set wrapped_line_count (count $english_wrapped)
            end

            for wrapped_index in (seq $wrapped_line_count)
                set -l original_segment $original_wrapped[$wrapped_index]
                set -l romaji_segment $romaji_wrapped[$wrapped_index]
                set -l english_segment $english_wrapped[$wrapped_index]
                printf '%s │ %s │ %s\n' \
                    (string pad -w $original_width --right "$original_segment") \
                    (string pad -w $romaji_width --right "$romaji_segment") \
                    "$english_segment"
            end
        end
    end | gum pager

    functions -e __lyrics_romaji_wrap_cell
end
