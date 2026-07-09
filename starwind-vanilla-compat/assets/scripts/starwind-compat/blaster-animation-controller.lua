-- Experimental: redirect only Starwind crossbow-class blasters to the
-- swblaster group. Vanilla bows and crossbows remain on native groups.
--
-- This script deliberately falls back to the native Crossbow animation when
-- the custom group was not loaded, so enabling it cannot leave a weapon with
-- no animation. See the README before enabling this manifest.

local animation = require('openmw.animation')
local interfaces = require('openmw.interfaces')
local types = require('openmw.types')

local redirecting = false

local function isStarwindBlaster()
    local weapon = types.Actor.getEquipment(self, types.Actor.EQUIPMENT_SLOT.CarriedRight)
    if not weapon or not types.Weapon.objectIsInstance(weapon) then
        return false
    end
    local record = types.Weapon.record(weapon)
    return record and record.id and record.id:match('^SW_') ~= nil
        and record.type == types.Weapon.TYPE.MarksmanCrossbow
end

local function replaceCrossbow(value)
    if type(value) ~= 'string' then
        return value
    end
    return (value:gsub('[Cc][Rr][Oo][Ss][Ss][Bb][Oo][Ww]', 'swblaster'))
end

local function remapOptions(options)
    local result = {}
    for key, value in pairs(options or {}) do
        result[key] = value
    end
    result.startKey = replaceCrossbow(result.startKey)
    result.stopKey = replaceCrossbow(result.stopKey)
    -- Older OpenMW API spelling is retained for compatibility with existing
    -- character-controller callers.
    result.startkey = replaceCrossbow(result.startkey)
    result.stopkey = replaceCrossbow(result.stopkey)
    return result
end

interfaces.AnimationController.addPlayBlendedAnimationHandler(function(groupName, options)
    if redirecting or not isStarwindBlaster() then
        return true
    end
    if type(groupName) ~= 'string' or not groupName:lower():find('crossbow', 1, true) then
        return true
    end

    local replacement = replaceCrossbow(groupName)
    if not animation.hasGroup(self, replacement) then
        return true
    end

    redirecting = true
    interfaces.AnimationController.playBlendedAnimation(replacement, remapOptions(options))
    redirecting = false
    return false
end)
