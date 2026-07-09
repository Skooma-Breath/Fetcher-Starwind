-- Keeps the original Book window for ordinary books, but layers a datapad
-- reader over Starwind's datapad records.  The Book UI mode still owns pause,
-- sound, and Esc-to-close behavior.

local types = require('openmw.types')
local ui = require('openmw.ui')
local util = require('openmw.util')

local tabletTexture = ui.texture {
    path = 'textures/starwind_compat/tablet_reader.dds',
}

local tabletElement = nil

local function cleanText(text)
    text = text or ''
    text = text:gsub('\r\n', '\n')
    text = text:gsub('<[bB][rR]%s*/?>', '\n')
    -- Starwind's datapads use Morrowind FONT markup. Lua UI text does not
    -- consume that markup, so show the readable content instead.
    text = text:gsub('<[^>]->', '')
    return text
end

local function isDatapad(book)
    if not book or not types.Book.objectIsInstance(book) then
        return false
    end
    local record = types.Book.record(book)
    if not record or not record.id or not record.model then
        return false
    end
    return record.id:match('^SW_') ~= nil and record.model:lower():find('datapad.nif', 1, true) ~= nil
end

local function hideTablet()
    if tabletElement then
        tabletElement:destroy()
        tabletElement = nil
    end
end

local function showTablet(book)
    hideTablet()
    local record = types.Book.record(book)
    tabletElement = ui.create({
        layer = 'Windows',
        type = ui.TYPE.Widget,
        props = {
            relativePosition = util.vector2(0.08, 0.29),
            relativeSize = util.vector2(0.84, 0.42),
            propagateEvents = false,
        },
        content = ui.content({
            {
                type = ui.TYPE.Image,
                props = {
                    resource = tabletTexture,
                    relativeSize = util.vector2(1, 1),
                },
            },
            {
                type = ui.TYPE.Text,
                props = {
                    position = util.vector2(56, 30),
                    relativeSize = util.vector2(1, 1),
                    size = util.vector2(-112, -64),
                    autoSize = false,
                    multiline = true,
                    wordWrap = true,
                    textSize = 16,
                    textColor = util.color.rgb(0.94, 0.92, 0.67),
                    textShadow = true,
                    textShadowColor = util.color.rgb(0.03, 0.08, 0.08),
                    text = record.name .. '\n\n' .. cleanText(record.text),
                },
            },
        }),
    })
end

return {
    eventHandlers = {
        UiModeChanged = function(data)
            if data.newMode == 'Book' and isDatapad(data.arg) then
                showTablet(data.arg)
            else
                hideTablet()
            end
        end,
    },
}
