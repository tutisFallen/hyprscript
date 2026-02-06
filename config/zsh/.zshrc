export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="spaceship"
plugins=(git z fzf)

SPACESHIP_PROMPT_ORDER=(
  user dir git exec_time line_sep
  jobs exit_code char
)

SPACESHIP_USER_SHOW=always
SPACESHIP_CHAR_SYMBOL="❯"
SPACESHIP_CHAR_SUFFIX=" "

source $ZSH/oh-my-zsh.sh
