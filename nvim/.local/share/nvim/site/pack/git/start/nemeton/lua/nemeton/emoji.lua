-- The `:name:` a forge draws as a picture.
--
-- GitLab renders gemoji shortcodes everywhere it renders markdown, so a
-- comment arrives with `:tada:` in the middle of a sentence and the
-- page it was written on showed 🎉. Read here as it was written, that
-- sentence has a word missing and a colon on each side of it.
--
-- Two halves, and they are opposite. What is *written* stays written:
-- the composer holds the text GitLab will be given, colons and all,
-- because that is what the forge renders and what the next person to
-- edit the comment has to see. What is *read* is drawn: the character,
-- in the width of one, wherever a note is drawn as prose. A suggestion
-- is the exception on both counts -- it is code, and code that says
-- `:tada:` says `:tada:`.
--
-- The names are the shortcodes, and the shortcodes are a list somebody
-- has to keep. This one is short on purpose: the whole gemoji set is
-- eighteen hundred names and most of them have never been typed into a
-- code review. What is here is what a review is written with -- the
-- reactions, the verdicts, the dozen things a comment points at -- and
-- a name that is not here is left exactly as it was typed, which is
-- what a forge does with one it does not know either.

local config = require("nemeton.config")

local M = {}

--- What starts the word this completes: the sigil is part of what is
--- inserted, because `tada` on its own is a word and `:tada:` is a
--- picture.
M.sigil = ":"

-- name -> the character it names.
M.by_name = {
  ["+1"] = "👍",
  ["-1"] = "👎",
  ["100"] = "💯",
  thumbsup = "👍",
  thumbsdown = "👎",
  ok_hand = "👌",
  clap = "👏",
  wave = "👋",
  raised_hands = "🙌",
  pray = "🙏",
  handshake = "🤝",
  muscle = "💪",
  point_up = "☝️",
  point_down = "👇",
  point_left = "👈",
  point_right = "👉",
  v = "✌️",
  crossed_fingers = "🤞",
  facepalm = "🤦",
  shrug = "🤷",
  bow = "🙇",
  eyes = "👀",
  brain = "🧠",

  grinning = "😀",
  smiley = "😃",
  smile = "😄",
  grin = "😁",
  laughing = "😆",
  sweat_smile = "😅",
  joy = "😂",
  rofl = "🤣",
  slightly_smiling_face = "🙂",
  upside_down_face = "🙃",
  wink = "😉",
  blush = "😊",
  innocent = "😇",
  heart_eyes = "😍",
  yum = "😋",
  stuck_out_tongue = "😛",
  stuck_out_tongue_winking_eye = "😜",
  hugs = "🤗",
  thinking = "🤔",
  zipper_mouth_face = "🤐",
  neutral_face = "😐",
  expressionless = "😑",
  no_mouth = "😶",
  smirk = "😏",
  unamused = "😒",
  roll_eyes = "🙄",
  grimacing = "😬",
  relieved = "😌",
  pensive = "😔",
  sleeping = "😴",
  mask = "😷",
  nauseated_face = "🤢",
  dizzy_face = "😵",
  exploding_head = "🤯",
  partying_face = "🥳",
  sunglasses = "😎",
  nerd_face = "🤓",
  confused = "😕",
  worried = "😟",
  slightly_frowning_face = "🙁",
  open_mouth = "😮",
  hushed = "😯",
  astonished = "😲",
  flushed = "😳",
  pleading_face = "🥺",
  fearful = "😨",
  cold_sweat = "😰",
  cry = "😢",
  sob = "😭",
  scream = "😱",
  confounded = "😖",
  persevere = "😣",
  disappointed = "😞",
  sweat = "😓",
  weary = "😩",
  tired_face = "😫",
  yawning_face = "🥱",
  triumph = "😤",
  rage = "😡",
  angry = "😠",
  smiling_imp = "😈",
  skull = "💀",
  poop = "💩",
  clown_face = "🤡",
  ghost = "👻",
  alien = "👽",
  robot = "🤖",

  heart = "❤️",
  broken_heart = "💔",
  two_hearts = "💕",
  sparkling_heart = "💖",
  blue_heart = "💙",
  green_heart = "💚",
  yellow_heart = "💛",
  purple_heart = "💜",
  orange_heart = "🧡",
  black_heart = "🖤",
  white_heart = "🤍",

  rocket = "🚀",
  tada = "🎉",
  confetti_ball = "🎊",
  fire = "🔥",
  boom = "💥",
  sparkles = "✨",
  star = "⭐",
  star2 = "🌟",
  zap = "⚡",
  bulb = "💡",
  wrench = "🔧",
  hammer = "🔨",
  gear = "⚙️",
  nut_and_bolt = "🔩",
  lock = "🔒",
  unlock = "🔓",
  key = "🔑",
  mag = "🔍",
  book = "📖",
  books = "📚",
  memo = "📝",
  pencil2 = "✏️",
  clipboard = "📋",
  package = "📦",
  gift = "🎁",
  hourglass = "⏳",
  alarm_clock = "⏰",
  watch = "⌚",
  calendar = "📅",
  chart_with_upwards_trend = "📈",
  chart_with_downwards_trend = "📉",
  bar_chart = "📊",
  computer = "💻",
  floppy_disk = "💾",
  iphone = "📱",
  email = "📧",
  envelope = "✉️",
  inbox_tray = "📥",
  outbox_tray = "📤",
  link = "🔗",
  paperclip = "📎",
  scissors = "✂️",
  wastebasket = "🗑️",
  microscope = "🔬",
  telescope = "🔭",
  balance_scale = "⚖️",
  crystal_ball = "🔮",
  dart = "🎯",
  trophy = "🏆",
  medal_sports = "🏅",
  first_place_medal = "🥇",
  game_die = "🎲",
  video_game = "🎮",
  art = "🎨",
  musical_note = "🎵",
  headphones = "🎧",
  camera = "📷",
  movie_camera = "🎥",
  clapper = "🎬",
  tv = "📺",
  radio = "📻",

  bug = "🐛",
  ant = "🐜",
  snail = "🐌",
  turtle = "🐢",
  penguin = "🐧",
  whale = "🐳",
  dolphin = "🐬",
  cat = "🐱",
  dog = "🐶",
  octopus = "🐙",
  honeybee = "🐝",
  snake = "🐍",
  dragon = "🐉",
  unicorn = "🦄",

  white_check_mark = "✅",
  heavy_check_mark = "✔️",
  x = "❌",
  warning = "⚠️",
  no_entry = "⛔",
  no_entry_sign = "🚫",
  question = "❓",
  grey_question = "❔",
  exclamation = "❗",
  bangbang = "‼️",
  information_source = "ℹ️",
  recycle = "♻️",
  construction = "🚧",
  stop_sign = "🛑",
  checkered_flag = "🏁",
  triangular_flag_on_post = "🚩",
  pushpin = "📌",
  round_pushpin = "📍",
  bookmark = "🔖",
  label = "🏷️",
  new = "🆕",
  ok = "🆗",
  arrow_up = "⬆️",
  arrow_down = "⬇️",
  arrow_left = "⬅️",
  arrow_right = "➡️",
  arrows_counterclockwise = "🔄",
  ["repeat"] = "🔁",

  coffee = "☕",
  tea = "🍵",
  beer = "🍺",
  beers = "🍻",
  champagne = "🍾",
  cake = "🎂",
  pizza = "🍕",
  hamburger = "🍔",
  taco = "🌮",
  apple = "🍎",
  banana = "🍌",
  cherries = "🍒",
  watermelon = "🍉",
  popcorn = "🍿",
  cookie = "🍪",
  chocolate_bar = "🍫",
  doughnut = "🍩",
  ice_cream = "🍨",

  sunny = "☀️",
  cloud = "☁️",
  rainbow = "🌈",
  snowflake = "❄️",
  snowman = "⛄",
  ocean = "🌊",
  earth_africa = "🌍",
  crescent_moon = "🌙",
  seedling = "🌱",
  herb = "🌿",
  four_leaf_clover = "🍀",
  maple_leaf = "🍁",
  cactus = "🌵",
  palm_tree = "🌴",
  evergreen_tree = "🌲",
  sunflower = "🌻",
  rose = "🌹",
  tulip = "🌷",
  cherry_blossom = "🌸",

  car = "🚗",
  bus = "🚌",
  train = "🚆",
  airplane = "✈️",
  ship = "🚢",
  bike = "🚲",
  ambulance = "🚑",
  fire_engine = "🚒",
  helicopter = "🚁",
  anchor = "⚓",
  sailboat = "⛵",
  house = "🏠",
  office = "🏢",
  factory = "🏭",
  bank = "🏦",
  hospital = "🏥",
  school = "🏫",
}

-- The names, sorted, worked out once: the table above is a map and a
-- completion menu is a list, and the order a menu comes up in must not
-- be whatever `pairs` felt like this time.
local sorted = nil
local function names()
  if not sorted then
    sorted = vim.tbl_keys(M.by_name)
    table.sort(sorted)
  end
  return sorted
end

--- `text` with every `:name:` this knows drawn as the character it
--- names, and every one it does not left exactly as it was written.
---
--- Display only. What is sent back when a comment is rewritten is what
--- its author typed -- the same promise the commit links are drawn
--- under.
function M.render(text)
  if type(text) ~= "string" or not config.comments.emoji then
    return text
  end
  if not text:find(":", 1, true) then
    return text
  end
  return (text:gsub(":([%w_+%-]+):", function(name)
    return M.by_name[name]
  end))
end

--- The names worth offering for `prefix` -- what was typed after the
--- `:`, and empty when nothing was.
---
--- What the name starts with first and what it merely contains second:
--- `:check` is reached for by somebody who wants `white_check_mark`,
--- and a menu that will not find it is a menu they stop opening.
function M.candidates(prefix)
  prefix = (prefix or ""):lower():gsub("^:", "")
  local first, second = {}, {}
  for _, name in ipairs(names()) do
    local at = name:find(prefix, 1, true)
    if prefix == "" or at == 1 then
      table.insert(first, name)
    elseif at then
      table.insert(second, name)
    end
  end
  return vim.list_extend(first, second)
end

--- Neovim's `omnifunc`, which is Vim's: asked for the start of the word
--- first and for the matches second. See `nemeton.mentions`, which
--- answers the other sigil the same way.
---
--- The word starts at the `:`, and both colons are inserted: GitLab
--- draws a picture for `:tada:` and prints the word for `:tada`.
function M.omnifunc(findstart, base)
  if findstart == 1 then
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local head = vim.api.nvim_get_current_line():sub(1, col)
    -- Preceded by nothing or by whitespace. A colon in the middle of a
    -- word is a path, a Ruby symbol, a key in a table or the end of a
    -- sentence's first half -- and a menu that comes up in all four is
    -- a menu that comes up while you are writing prose.
    local at = head:match("^():[%w_+%-]*$") or head:match("[%s([{'\"]():[%w_+%-]*$")
    return at and (at - 1) or -3
  end
  local items = {}
  for _, name in ipairs(M.candidates(base)) do
    table.insert(items, {
      word = (":%s:"):format(name),
      -- The character itself, beside the name: the name is what is
      -- typed and the picture is what is meant, and nobody remembers
      -- which of `tada` and `confetti_ball` is which.
      menu = M.by_name[name],
    })
  end
  return items
end

return M
