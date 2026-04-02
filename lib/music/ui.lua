---@diagnostic disable: undefined-global
local util = require("music.util")

local UI = {}
UI.__index = UI

local defaultTheme = {
    background = colors.black,
    surface = colors.gray,
    surfaceAlt = colors.lightGray,
    text = colors.white,
    accent = colors.pink,
    selected = colors.magenta,
    selectedText = colors.white,
    button = colors.gray,
    buttonActive = colors.purple,
    buttonText = colors.white,
    progress = colors.magenta,
    progressBackground = colors.gray,
    header = colors.purple,
    titleBar = colors.gray,
    actionBar = colors.magenta,
    label = colors.lightGray,
    labelText = colors.white
}

function UI.new(target, theme)
    return setmetatable({
        target = target,
        theme = theme or defaultTheme,
        hits = {},
        width = 0,
        height = 0
    }, UI)
end

function UI:refreshSize()
    self.width, self.height = self.target.getSize()
end

function UI:resetHits()
    self.hits = {}
end

function UI:addHit(id, x1, y1, x2, y2, meta)
    self.hits[#self.hits + 1] = {
        id = id,
        x1 = x1,
        y1 = y1,
        x2 = x2,
        y2 = y2,
        meta = meta or {}
    }
end

function UI:hitTest(x, y)
    for index = #self.hits, 1, -1 do
        local hit = self.hits[index]
        if x >= hit.x1 and x <= hit.x2 and y >= hit.y1 and y <= hit.y2 then
            return hit
        end
    end
    return nil
end

function UI:fill(x, y, width, height, background, textColor, char)
    if width <= 0 or height <= 0 then
        return
    end

    self.target.setBackgroundColor(background or self.theme.background)
    self.target.setTextColor(textColor or self.theme.text)
    local content = string.rep(char or " ", width)
    for row = 0, height - 1 do
        self.target.setCursorPos(x, y + row)
        self.target.write(content)
    end
end

function UI:text(x, y, value, textColor, background)
    if background then
        self.target.setBackgroundColor(background)
    end
    self.target.setTextColor(textColor or self.theme.text)
    self.target.setCursorPos(x, y)
    self.target.write(value)
end

function UI:centerText(x, y, width, value, textColor, background)
    value = util.truncate(value, width)
    local offset = math.max(0, math.floor((width - #value) / 2))
    self:text(x + offset, y, value, textColor, background)
end

function UI:panel(x, y, width, height, title, accent)
    accent = accent or self.theme.accent
    self:fill(x, y, width, height, self.theme.surface, self.theme.text, " ")

    if height >= 1 then
        self:fill(x, y, width, 1, accent)
        self:text(x + 1, y, util.truncate(title or "", math.max(0, width - 2)), self.theme.text, accent)
    end
end

function UI:badge(x, y, text, background, foreground)
    local width = #text + 2
    self:fill(x, y, width, 1, background or self.theme.accent)
    self:text(x + 1, y, text, foreground or self.theme.text, background or self.theme.accent)
    return width
end

function UI:button(id, x, y, width, label, options)
    options = options or {}
    local bg = options.active and self.theme.buttonActive or self.theme.button
    local fg = options.foreground or self.theme.buttonText
    local height = math.max(1, options.height or 2)

    self:fill(x, y, width, height, bg, fg, " ")
    self:centerText(x, y + math.floor((height - 1) / 2), width, label, fg, bg)
    self:addHit(id, x, y, x + width - 1, y + height - 1, options.meta)
end

function UI:progress(x, y, width, ratio, fillColor, background)
    ratio = util.clamp(ratio or 0, 0, 1)
    local filled = math.floor(width * ratio + 0.5)
    self:fill(x, y, width, 1, background or self.theme.progressBackground)
    if filled > 0 then
        self:fill(x, y, filled, 1, fillColor or self.theme.progress)
    end
end

function UI:list(id, x, y, width, height, items, selectedIndex, scroll, options)
    options = options or {}
    items = items or {}

    local innerX = x
    local innerY = y
    local innerWidth = width
    local innerHeight = height

    if not options.plain then
        self:panel(x, y, width, height, options.title or "List", options.accent)
        innerX = x + 1
        innerY = y + 1
        innerWidth = math.max(1, width - 2)
        innerHeight = math.max(1, height - 1)
    end

    local visible = innerHeight
    local maxScroll = math.max(1, #items - visible + 1)
    local hasScrollbar = #items > visible and innerWidth >= 2
    local contentWidth = hasScrollbar and (innerWidth - 1) or innerWidth
    scroll = util.clamp(scroll or 1, 1, maxScroll)

    self:fill(innerX, innerY, innerWidth, innerHeight, options.background or self.theme.surface, self.theme.text, " ")

    for row = 1, visible do
        local index = scroll + row - 1
        if index > #items then
            break
        end

        local item = items[index]
        local label = options.formatter and options.formatter(item, index) or tostring(item)
        local isSelected = index == selectedIndex
        local background = isSelected and self.theme.selected or (options.background or self.theme.surface)
        local foreground = isSelected and self.theme.selectedText or self.theme.text
        local targetY = innerY + row - 1

        self:fill(innerX, targetY, innerWidth, 1, background, foreground, " ")
        self:text(innerX + 1, targetY, util.truncate(label, math.max(0, contentWidth - 2)), foreground, background)
        self:addHit(id, innerX, targetY, innerX + contentWidth - 1, targetY, {
            kind = "list",
            index = index,
            item = item
        })
    end

    if hasScrollbar then
        local barX = innerX + innerWidth - 1
        self:fill(barX, innerY, 1, innerHeight, self.theme.surfaceAlt)

        local knobSize = math.max(1, math.floor(innerHeight * (visible / #items) + 0.5))
        local knobRange = math.max(0, innerHeight - knobSize)
        local knobOffset = 0
        if maxScroll > 1 then
            knobOffset = math.floor(((scroll - 1) / (maxScroll - 1)) * knobRange + 0.5)
        end
        self:fill(barX, innerY + knobOffset, 1, knobSize, self.theme.accent)

        for row = 1, innerHeight do
            local rowRatio = innerHeight <= 1 and 0 or ((row - 1) / (innerHeight - 1))
            local targetScroll = math.floor((rowRatio * math.max(0, maxScroll - 1)) + 0.5) + 1
            self:addHit(id, barX, innerY + row - 1, barX, innerY + row - 1, {
                kind = "scrollbar",
                scroll = util.clamp(targetScroll, 1, maxScroll)
            })
        end
    end

    return scroll, visible
end

return UI