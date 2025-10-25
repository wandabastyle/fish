if status is-interactive
    # Hide the welcome message
    function fish_greeting; end

    # If you want Starship, do NOT load any Fish prompt themes.
    # (Comment out any theme lines like "theme_tokyonight moon")
    # theme_tokyonight moon

    # Initialize Starship
    starship init fish | source

		# Zoxide
		zoxide init --cmd=cd fish | source

    # --- Aliases ---
    alias vim='nvim'
    alias cat='bat'
    alias ls='eza -al --color=always --group-directories-first'
    alias la='eza -a --color=always --group-directories-first'
    alias ll='eza -l --color=always --group-directories-first'
    alias lt='eza -aT --color=always --group-directories-first'
    alias l.='eza -a | egrep "^\."'
end

