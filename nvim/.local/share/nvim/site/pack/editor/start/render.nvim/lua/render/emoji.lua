-- The `:name:` markdown draws as a picture.
--
-- GitHub and GitLab both render gemoji shortcodes wherever they render
-- markdown, so a file arrives with `:tada:` in the middle of a sentence
-- and the page it is read on shows 🎉. Read as it was written, that
-- sentence has a word missing and a colon on each side of it.
--
-- Drawn only: the file says `:tada:` and goes on saying it. Code is the
-- exception -- code that says `:tada:` says `:tada:` -- which is the
-- caller's to know, since this is handed prose and nothing else.
--
-- The list is short on purpose: the whole gemoji set is eighteen
-- hundred names and most of them are never typed. A name that is not
-- here is left exactly as it was written, which is what a page does
-- with one it does not know either.
--
-- None of them carry U+FE0F, the variation selector that asks for the
-- coloured picture rather than the black-and-white glyph -- `❤️` is
-- written here as `❤`. It is put on when drawn, where Neovim counts the
-- pair as two columns (0.11 on): a terminal with a colour emoji font
-- draws `⚠` two columns wide whatever it is asked, and where Neovim
-- and the terminal between (tmux) count it as one, it covers the
-- character after it. Asked for the picture, all three agree on two.
-- Where Neovim counts one either way, the bare glyph is the one all of
-- them can agree on.

local M = {}

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
  point_up = "☝",
  point_down = "👇",
  point_left = "👈",
  point_right = "👉",
  v = "✌",
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

  heart = "❤",
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
  gear = "⚙",
  nut_and_bolt = "🔩",
  lock = "🔒",
  unlock = "🔓",
  key = "🔑",
  mag = "🔍",
  book = "📖",
  books = "📚",
  memo = "📝",
  pencil2 = "✏",
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
  envelope = "✉",
  inbox_tray = "📥",
  outbox_tray = "📤",
  link = "🔗",
  paperclip = "📎",
  scissors = "✂",
  wastebasket = "🗑",
  microscope = "🔬",
  telescope = "🔭",
  balance_scale = "⚖",
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
  heavy_check_mark = "✔",
  x = "❌",
  warning = "⚠",
  no_entry = "⛔",
  no_entry_sign = "🚫",
  question = "❓",
  grey_question = "❔",
  exclamation = "❗",
  bangbang = "‼",
  information_source = "ℹ",
  recycle = "♻",
  construction = "🚧",
  stop_sign = "🛑",
  checkered_flag = "🏁",
  triangular_flag_on_post = "🚩",
  pushpin = "📌",
  round_pushpin = "📍",
  bookmark = "🔖",
  label = "🏷",
  new = "🆕",
  ok = "🆗",
  arrow_up = "⬆",
  arrow_down = "⬇",
  arrow_left = "⬅",
  arrow_right = "➡",
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

  sunny = "☀",
  cloud = "☁",
  rainbow = "🌈",
  snowflake = "❄",
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
  airplane = "✈",
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

local FE0F = "\239\184\143"

-- Whether this Neovim counts a glyph with U+FE0F after it as two
-- columns, once, the first time it matters.
local wide
local function picture(char)
  if wide == nil then
    wide = vim.fn.strdisplaywidth("⚠" .. FE0F) == 2
  end
  if wide and vim.fn.strdisplaywidth(char) == 1 then
    return char .. FE0F
  end
  return char
end

--- `text` with every `:name:` this knows drawn as the character it
--- names, and every one it does not left exactly as it was written.
function M.render(text)
  if type(text) ~= "string" or not text:find(":", 1, true) then
    return text
  end
  return (
    text:gsub(":([%w_+%-]+):", function(name)
      local char = M.by_name[name]
      return char and picture(char)
    end)
  )
end

return M
