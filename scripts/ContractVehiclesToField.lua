--
-- ContractVehiclesToField
--
-- Delivers leased contract vehicles to the contract field instead of the
-- shop spawn area. Only missions that are tied to a field (mission.field) are
-- affected; every other mission type keeps the base game behaviour.
--
-- Base game reference (FS25):
--   AbstractMission:spawnVehicles()      -> loops vehiclesToLoad, calls spawnVehicle(info)
--   AbstractMission:spawnVehicle(info)   -> VehicleLoadingData + setLoadingPlace(storeSpawnPlaces)
--   AbstractMission:isSpawnSpaceAvailable() -> checks the shop spawn area for free space
--

ContractVehiclesToField = {}
ContractVehiclesToField.MOD_NAME = g_currentModName

-- Gap between vehicles parked side by side (m)
ContractVehiclesToField.SPACING = 2.5
-- Fallback only: how far from the field entry point towards the field center the row is placed (m)
ContractVehiclesToField.INSET = 4.0
-- Height above terrain the vehicles are spawned at, they settle onto the ground (m)
ContractVehiclesToField.TERRAIN_OFFSET = 0.3

-- Edge placement: vehicles are lined up along the field edge closest to a road, facing into the field
ContractVehiclesToField.USE_FIELD_EDGE = true
-- Distance from the field edge to the rear of the vehicles, inside the field (m)
ContractVehiclesToField.EDGE_INSET = 2.0
-- Roads further away from the field than this are ignored (m)
ContractVehiclesToField.MAX_ROAD_DISTANCE = 150
-- Sampling steps for roads and the field outline (m), larger is faster but less exact
ContractVehiclesToField.ROAD_SAMPLE_STEP = 8
ContractVehiclesToField.EDGE_SAMPLE_STEP = 4


local function log(fmt, ...)
    Logging.info("[%s] " .. fmt, ContractVehiclesToField.MOD_NAME, ...)
end


-------------------------------------------------------------------------------
-- Field edge placement
-------------------------------------------------------------------------------

---Field outline as a list of {x, z} world positions
function ContractVehiclesToField.getFieldOutline(field)
    local points = {}
    for _, node in ipairs(field.polygonPoints or {}) do
        if entityExists(node) then
            local x, _, z = getWorldTranslation(node)
            table.insert(points, {x = x, z = z})
        end
    end

    if #points < 3 then
        return nil
    end
    return points
end


---Point in polygon test (ray casting)
function ContractVehiclesToField.isInsideOutline(points, x, z)
    local inside = false
    local j = #points
    for i = 1, #points do
        local a, b = points[i], points[j]
        if (a.z > z) ~= (b.z > z) and x < (b.x - a.x) * (z - a.z) / (b.z - a.z) + a.x then
            inside = not inside
        end
        j = i
    end
    return inside
end


---Sample points of all AI road splines inside the given box
function ContractVehiclesToField.getRoadPoints(minX, maxX, minZ, maxZ)
    local aiSystem = g_currentMission.aiSystem
    if aiSystem == nil or aiSystem.roadSplines == nil then
        return {}
    end

    local points = {}
    for _, spline in ipairs(aiSystem.roadSplines) do
        if entityExists(spline) then
            local length = getSplineLength(spline)
            if length ~= nil and length > 0 then
                local steps = math.max(1, math.ceil(length / ContractVehiclesToField.ROAD_SAMPLE_STEP))
                for s = 0, steps do
                    local x, _, z = getSplinePosition(spline, s / steps)
                    if x >= minX and x <= maxX and z >= minZ and z <= maxZ then
                        table.insert(points, {x = x, z = z})
                    end
                end
            end
        end
    end

    return points
end


---Anchor on the field edge closest to a road: returns anchorX, anchorZ, dirX, dirZ (dir points into the field)
-- or nil when the field has no usable outline.
function ContractVehiclesToField.getEdgeAnchor(field, outline, rowWidth)
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(outline) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    local margin = ContractVehiclesToField.MAX_ROAD_DISTANCE
    local roads = ContractVehiclesToField.getRoadPoints(minX - margin, maxX + margin, minZ - margin, maxZ + margin)

    -- reference when no road is near: the field label position (closest edge to the middle)
    local refX, refZ = field.posX, field.posZ

    local best = {distSq = math.huge}
    local numPoints = #outline
    for i = 1, numPoints do
        local a, b = outline[i], outline[i % numPoints + 1]
        local segLength = MathUtil.vector2Length(b.x - a.x, b.z - a.z)
        if segLength > 0.5 then
            local steps = math.max(1, math.ceil(segLength / ContractVehiclesToField.EDGE_SAMPLE_STEP))
            for s = 0, steps do
                local t = s / steps
                local x, z = a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t

                local distSq = math.huge
                if #roads > 0 then
                    for _, r in ipairs(roads) do
                        local dx, dz = r.x - x, r.z - z
                        local d = dx * dx + dz * dz
                        if d < distSq then
                            distSq = d
                        end
                    end
                else
                    distSq = (refX - x) ^ 2 + (refZ - z) ^ 2
                end

                if distSq < best.distSq then
                    best = {distSq = distSq, a = a, b = b, t = t, segLength = segLength}
                end
            end
        end
    end

    if best.a == nil then
        return nil
    end

    local a, b, segLength = best.a, best.b, best.segLength
    local tanX, tanZ = (b.x - a.x) / segLength, (b.z - a.z) / segLength

    -- keep the whole row on this straight piece of edge when it is long enough
    local along = best.t * segLength
    local half = rowWidth * 0.5 + 1
    if segLength >= 2 * half then
        along = math.min(math.max(along, half), segLength - half)
    else
        along = segLength * 0.5
    end
    local edgeX, edgeZ = a.x + tanX * along, a.z + tanZ * along

    -- inward direction: the side of the edge that is inside the field
    local dirX, dirZ = -tanZ, tanX
    if not ContractVehiclesToField.isInsideOutline(outline, edgeX + dirX * 2, edgeZ + dirZ * 2) then
        dirX, dirZ = -dirX, -dirZ
    end

    local inset = ContractVehiclesToField.EDGE_INSET
    if #roads > 0 then
        log("Field %s: vehicles placed on the field edge %.0fm from the nearest road", tostring(field:getName()), math.sqrt(best.distSq))
    else
        log("Field %s: no road nearby, vehicles placed on the field edge closest to the field middle", tostring(field:getName()))
    end

    return edgeX + dirX * inset, edgeZ + dirZ * inset, dirX, dirZ
end


---Fallback anchor: the field's teleport node (map entry point) when present, otherwise the field label position.
function ContractVehiclesToField.getFieldAnchor(field)
    local centerX, centerZ = field.posX, field.posZ
    local anchorX, anchorZ = centerX, centerZ

    if field.teleportNode ~= nil and entityExists(field.teleportNode) then
        local x, _, z = getWorldTranslation(field.teleportNode)
        anchorX, anchorZ = x, z
    end

    local dirX, dirZ = centerX - anchorX, centerZ - anchorZ
    local distance = MathUtil.vector2Length(dirX, dirZ)
    if distance < 1 then
        -- no usable direction (no teleport node), just face north
        dirX, dirZ = 0, 1
    else
        dirX, dirZ = dirX / distance, dirZ / distance
    end

    local inset = math.min(ContractVehiclesToField.INSET, distance * 0.5)

    return anchorX + dirX * inset, anchorZ + dirZ * inset, dirX, dirZ
end


---Computes a spawn slot {x, z, yRot} for each entry of vehiclesToLoad.
-- Vehicles are placed side by side in one row, centered on the anchor, rear ends aligned
-- with the anchor line so the whole row sits inside the field.
function ContractVehiclesToField.computeLayout(field, vehiclesToLoad)
    local items = {}
    local totalWidth = 0

    for i, info in ipairs(vehiclesToLoad) do
        local storeItem = g_storeManager:getItemByXMLFilename(info.filename)
        if storeItem == nil then
            return nil
        end

        local yRot = storeItem.rotation or 0
        if storeItem.spawnRotationOffset ~= nil then
            yRot = yRot + storeItem.spawnRotationOffset[2]
        end

        local size = StoreItemUtil.getSizeValues(info.filename, "vehicle", yRot, info.configurations)

        items[i] = {width = size.width, length = size.length, yRot = yRot}
        totalWidth = totalWidth + size.width
    end

    totalWidth = totalWidth + ContractVehiclesToField.SPACING * math.max(#items - 1, 0)

    -- preferred: along the field edge nearest a road; the row is only used if every vehicle ends up inside the field
    if ContractVehiclesToField.USE_FIELD_EDGE then
        local outline = ContractVehiclesToField.getFieldOutline(field)
        if outline ~= nil then
            local anchorX, anchorZ, dirX, dirZ = ContractVehiclesToField.getEdgeAnchor(field, outline, totalWidth)
            if anchorX ~= nil then
                local slots = ContractVehiclesToField.buildRow(items, totalWidth, anchorX, anchorZ, dirX, dirZ)
                local allInside = true
                for _, slot in ipairs(slots) do
                    if not ContractVehiclesToField.isInsideOutline(outline, slot.x, slot.z) then
                        allInside = false
                        break
                    end
                end
                if allInside then
                    return slots
                end
                log("Field edge too narrow for the vehicles, using the field entry point instead")
            end
        end
    end

    local anchorX, anchorZ, dirX, dirZ = ContractVehiclesToField.getFieldAnchor(field)
    return ContractVehiclesToField.buildRow(items, totalWidth, anchorX, anchorZ, dirX, dirZ)
end


---One row of vehicles side by side, centered on the anchor, rear ends on the anchor line, facing dir
function ContractVehiclesToField.buildRow(items, totalWidth, anchorX, anchorZ, dirX, dirZ)
    local perpX, perpZ = dirZ, -dirX
    local faceYRot = MathUtil.getYRotationFromDirection(dirX, dirZ)

    local slots = {}
    local offset = -totalWidth * 0.5

    for i, item in ipairs(items) do
        local side = offset + item.width * 0.5
        local forward = item.length * 0.5

        slots[i] = {
            x = anchorX + perpX * side + dirX * forward,
            z = anchorZ + perpZ * side + dirZ * forward,
            -- same formula as VehicleLoadingData:setLoadingPlace (store rotation + place direction)
            yRot = faceYRot + item.yRot
        }

        offset = offset + item.width + ContractVehiclesToField.SPACING
    end

    return slots
end


---Same as AbstractMission:spawnVehicle(info), but at a fixed position instead of the shop spawn places
function ContractVehiclesToField.spawnVehicleAt(mission, info, slot)
    local data = VehicleLoadingData.new()
    data:setFilename(info.filename)
    if data.isValid then
        if info.configurations ~= nil then
            data:setConfigurations(info.configurations)
        end

        data:setPosition(slot.x, nil, slot.z, ContractVehiclesToField.TERRAIN_OFFSET)
        data:setRotation(0, slot.yRot, 0)
        data:setPropertyState(VehiclePropertyState.MISSION)
        data:setOwnerFarmId(mission.farmId)

        table.insert(mission.pendingVehicleLoadingData, data)

        -- same callback and arguments as the base game, so AbstractMission:onSpawnedVehicle works unchanged
        local loadingInfo = {loadingData = data, vehicleInfo = info}
        data:load(mission.onSpawnedVehicle, mission, loadingInfo)
    end
end


---Overwrites AbstractMission:spawnVehicles()
function ContractVehiclesToField.spawnVehicles(mission, superFunc)
    local field = mission.field
    if field == nil or mission.vehiclesToLoad == nil or #mission.vehiclesToLoad == 0 then
        return superFunc(mission)
    end

    local success, slots = pcall(ContractVehiclesToField.computeLayout, field, mission.vehiclesToLoad)
    if not success or slots == nil then
        log("Could not compute field layout (%s), using shop spawn instead", tostring(slots))
        return superFunc(mission)
    end

    for i, info in ipairs(mission.vehiclesToLoad) do
        ContractVehiclesToField.spawnVehicleAt(mission, info, slots[i])
    end

    mission.spawnedVehicles = #mission.vehiclesToLoad > 0
    -- remembered so the player can be told once all vehicles finished loading (see finishedPreparing)
    mission.cvtfDeliveredToField = mission.spawnedVehicles

    log("Delivered %d leased vehicle(s) to field %s", #mission.vehiclesToLoad, tostring(field:getName()))
end


---Overwrites AbstractMission:isSpawnSpaceAvailable()
-- Field missions don't use the shop spawn area anymore, so a full shop must not block leasing.
function ContractVehiclesToField.isSpawnSpaceAvailable(mission, superFunc)
    if mission.field ~= nil then
        return true
    end

    return superFunc(mission)
end


---Shows "vehicles delivered to field X" to the players of the farm that started the contract
function ContractVehiclesToField.showDeliveredMessage(farmId, fieldId, numVehicles)
    local mission = g_currentMission
    if mission == nil or not mission:getIsClient() or mission:getFarmId() ~= farmId then
        return
    end

    local text = string.format(g_i18n:getText("cvtf_vehiclesDelivered"), numVehicles, tostring(fieldId))
    mission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end


---Appended to AbstractMission:finishedPreparing() (server only, called once all leased vehicles are loaded)
function ContractVehiclesToField.finishedPreparing(mission)
    if not mission.isServer or not mission.cvtfDeliveredToField or mission.field == nil then
        return
    end
    mission.cvtfDeliveredToField = nil

    local fieldId = mission.field:getId()
    local numVehicles = #mission.vehicles

    -- remote players
    g_server:broadcastEvent(ContractVehiclesToFieldEvent.new(mission.farmId, fieldId, numVehicles), false)
    -- single player / host
    ContractVehiclesToField.showDeliveredMessage(mission.farmId, fieldId, numVehicles)
end


---Server -> client event carrying the delivery message
ContractVehiclesToFieldEvent = {}
local ContractVehiclesToFieldEvent_mt = Class(ContractVehiclesToFieldEvent, Event)
InitEventClass(ContractVehiclesToFieldEvent, "ContractVehiclesToFieldEvent")

function ContractVehiclesToFieldEvent.emptyNew()
    return Event.new(ContractVehiclesToFieldEvent_mt)
end

function ContractVehiclesToFieldEvent.new(farmId, fieldId, numVehicles)
    local self = ContractVehiclesToFieldEvent.emptyNew()
    self.farmId = farmId
    self.fieldId = fieldId
    self.numVehicles = numVehicles
    return self
end

function ContractVehiclesToFieldEvent:writeStream(streamId, connection)
    streamWriteUIntN(streamId, self.farmId, FarmManager.FARM_ID_SEND_NUM_BITS)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteUInt8(streamId, math.min(self.numVehicles, 255))
end

function ContractVehiclesToFieldEvent:readStream(streamId, connection)
    self.farmId = streamReadUIntN(streamId, FarmManager.FARM_ID_SEND_NUM_BITS)
    self.fieldId = streamReadInt32(streamId)
    self.numVehicles = streamReadUInt8(streamId)
    self:run(connection)
end

function ContractVehiclesToFieldEvent:run(connection)
    -- only accept this from the server
    if connection:getIsServer() then
        ContractVehiclesToField.showDeliveredMessage(self.farmId, self.fieldId, self.numVehicles)
    end
end


AbstractMission.finishedPreparing = Utils.appendedFunction(AbstractMission.finishedPreparing, ContractVehiclesToField.finishedPreparing)
AbstractMission.spawnVehicles = Utils.overwrittenFunction(AbstractMission.spawnVehicles, ContractVehiclesToField.spawnVehicles)
AbstractMission.isSpawnSpaceAvailable = Utils.overwrittenFunction(AbstractMission.isSpawnSpaceAvailable, ContractVehiclesToField.isSpawnSpaceAvailable)
