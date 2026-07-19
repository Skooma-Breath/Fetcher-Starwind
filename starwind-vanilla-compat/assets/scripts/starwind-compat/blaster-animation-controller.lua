-- Player-side compatibility fallback: redirect Starwind bow-class pistols to
-- the private swblaster handgun group. Vanilla bows remain native, while
-- Starwind crossbow-class rifles retain their native rifle stance.
--
-- The Fetcher multiplayer engine performs the same selection for all character
-- controllers (including remote-player proxies). This handler keeps local
-- behavior correct on compatible clients without that engine route. It falls
-- back to the native Crossbow animation if the private group was not loaded.

local animation = require('openmw.animation')
local interfaces = require('openmw.interfaces')
local types = require('openmw.types')

local redirecting = false

local function isStarwindPistol()
    local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not weapon or not types.Weapon.objectIsInstance(weapon) then
        return false
    end
    local record = types.Weapon.record(weapon)
    return record and record.id and record.id:match('^SW_') ~= nil
        and record.type == types.Weapon.TYPE.MarksmanBow
end

local function replaceBow(value)
    if type(value) ~= 'string' then
        return value
    end
    return (value:gsub('[Bb][Oo][Ww][Aa][Nn][Dd][Aa][Rr][Rr][Oo][Ww]', 'swblaster'))
end

local function remapOptions(options)
    local result = {}
    for key, value in pairs(options or {}) do
        result[key] = value
    end
    result.startKey = replaceBow(result.startKey)
    result.stopKey = replaceBow(result.stopKey)
    -- Older OpenMW API spelling is retained for compatibility with existing
    -- character-controller callers.
    result.startkey = replaceBow(result.startkey)
    result.stopkey = replaceBow(result.stopkey)
    return result
end

interfaces.AnimationController.addPlayBlendedAnimationHandler(function(groupName, options)
    if redirecting or not isStarwindPistol() then
        return true
    end
    if type(groupName) ~= 'string' or not groupName:lower():find('bowandarrow', 1, true) then
        return true
    end

    local replacement = replaceBow(groupName)
    if not animation.hasGroup(self, replacement) then
        return true
    end

    redirecting = true
    interfaces.AnimationController.playBlendedAnimation(replacement, remapOptions(options))
    redirecting = false
    return false
end)
