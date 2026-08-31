local track_colors = {}

local PALETTE = {}
local TOTAL_COLORS = 128

local function hsv_to_rgb(h, s, v)
  local r, g, b
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  elseif i == 5 then r, g, b = v, p, q
  end
  return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

for i = 0, TOTAL_COLORS - 1 do
  local hue = i / TOTAL_COLORS
  local saturation = (i % 2 == 0) and 0.45 or 0.55
  local value = (i % 2 == 0) and 0.85 or 0.75
  local r, g, b = hsv_to_rgb(hue, saturation, value)

  PALETTE[#PALETTE + 1] = {
    r = r,
    g = g,
    b = b
  }
end

function track_colors.get_color_for_name(identity_key)
  local hash = 0
  local text = tostring(identity_key or "")

  for i = 1, #text do
    hash = (hash * 31 + text:byte(i)) % 100000000
  end

  local palette_index = (hash % #PALETTE) + 1
  return PALETTE[palette_index]
end

function track_colors.get_random_color()
  local palette_index = math.random(1, #PALETTE)
  return PALETTE[palette_index]
end

return track_colors
