function lyrics --description "Search and display song lyrics from LRCLIB"
    if test (count $argv) -eq 0
        echo "Usage: lyrics <artist> <song>"
        return 1
    end

    set -l query (string join " " $argv)

    curl -fsSG 'https://lrclib.net/api/search' \
        --data-urlencode "q=$query" |
    jq -er '
        if length == 0 then
            error("No results")
        else
            .[0] |
            "🎵 \(.artistName)\n♪ \(.trackName)\n\n\(.plainLyrics // "No lyrics available.")"
        end
    ' 2>/dev/null |
    gum pager

    if test $status -ne 0
        echo "No lyrics found for '$query'."
        return 1
    end
end
