local util = require("lualib.util")

local M = {}

local function inserters_in_position(bp_entities, starting_index)
  local out = {}
  local x = bp_entities[starting_index].position.x
  local y = bp_entities[starting_index].position.y
  for i=starting_index,#bp_entities do
    local ent = bp_entities[i]
    if ent.position.x == x and ent.position.y == y and util.is_miniloader_inserter(ent) then
      out[#out+1] = ent
    else
      break
    end
  end
  return out
end

local function tag_with_configuration(surface, bp_entity)
  local inserters = surface.find_entities_filtered{ type = "inserter", position = bp_entity.position }
  if not inserters[1] then return end
  tags = {}
  tags.filter_settings = util.get_loader_filter_settings(inserters[1])
  local right_inserter = nil
  for i=1,#inserters do
    if util.get_inserter_lane(inserters[i]) == "right" then
      right_inserter = inserters[i]
      break
    end
  end
  if right_inserter ~= nil then
    tags.right_lane_settings = util.capture_settings(right_inserter)
  elseif global.debug then
    game.print("tag_with_configuration could not find right inserter ".. bp_entity.entity_number)
  end
  bp_entity.tags = tags
end

local function find_slaves(miniloader_inserters, saved, to_remove)
  for i = 1, #miniloader_inserters do
    local inserter = miniloader_inserters[i]
    if inserter.entity_number ~= saved.entity_number then
      to_remove[inserter.entity_number] = true
    end
  end
end

local function remove_connections(bp_entity, to_remove_set)
  local connections = bp_entity.connections
  if not connections then
    return
  end
  for circuit_id, circuit_connections in pairs(connections) do
    if not circuit_id:find("^Cu") then -- ignore copper cables on power switch
      for wire_name, wire_connections in pairs(circuit_connections) do
        local new_wire_connections = {}
        for _, connection in ipairs(wire_connections) do
          if not to_remove_set[connection.entity_id] then
            new_wire_connections[#new_wire_connections+1] = connection
          end
        end
        if next(new_wire_connections) then
          circuit_connections[wire_name] = new_wire_connections
        else
          circuit_connections[wire_name] = nil
        end
      end
    end
  end
end

local function remove_entities(bp_entities, to_remove_set)
  local cnt = #bp_entities
  for i=1,cnt do
    remove_connections(bp_entities[i], to_remove_set)
  end

  local w = 1
  for r=1,cnt do
    if not to_remove_set[bp_entities[r].entity_number] then
      bp_entities[w] = bp_entities[r]
      w = w + 1
    end
  end
  for i=w,cnt do
    bp_entities[i] = nil
  end
end

function M.is_setup_bp(stack)
  return stack and
    stack.valid and
    stack.valid_for_read and
    stack.is_blueprint and
    stack.is_blueprint_setup()
end

local huge = math.huge
function M.bounding_box(bp_entities)
  local left = math.huge
  local top = math.huge
  local right = -math.huge
  local bottom = -math.huge

  for _, e in pairs(bp_entities) do
    local pos = e.position
    if pos.x < left then left = pos.x - 0.5 end
    if pos.y < top then top = pos.y - 0.5 end
    if pos.x > right then right = pos.x + 0.5 end
    if pos.y > bottom then bottom = pos.y + 0.5 end
  end

  local center_x = (right + left) / 2
  local center_y = (bottom + top) / 2

  return {
    left_top = {x = left - center_x, y = top - center_y},
    right_bottom = {x = right - center_x, y = bottom - center_y},
    center = {x = center_x, y = center_y},
  }
end

function M.get_blueprint_to_setup(player_index)
  local player = game.players[player_index]

  -- normal drag-select
  local blueprint_to_setup = player.blueprint_to_setup
  if blueprint_to_setup
  and blueprint_to_setup.valid_for_read
  and blueprint_to_setup.is_blueprint_setup() then
    return blueprint_to_setup
  end

  -- alt drag-select (skips configuration dialog)
  local cursor_stack = player.cursor_stack
  if cursor_stack
  and cursor_stack.valid_for_read
  and cursor_stack.is_blueprint
  and cursor_stack.is_blueprint_setup() then
    local bp = cursor_stack
    while bp.is_blueprint_book do
      bp = bp.get_inventory(defines.inventory.item_main)[bp.active_index]
    end
    return bp
  end

  -- update of existing blueprint
  local opened_blueprint = global.previous_opened_blueprint_for[player_index]
  if  opened_blueprint
  and opened_blueprint.tick == game.tick
  and opened_blueprint.blueprint
  and opened_blueprint.blueprint.valid_for_read
  and opened_blueprint.blueprint.is_blueprint_setup() then
    return opened_blueprint.blueprint
  end
end

function M.filter_miniloaders(bp, surface)
  local bp_entities = bp.get_blueprint_entities()
  if not bp_entities then
    return
  end
  local to_remove = {}
  local i = 1
  while i <= #bp_entities do
    local ent = bp_entities[i]
    if util.is_miniloader_inserter(ent) then
      local overlapping = inserters_in_position(bp_entities, i)
      local left_inserter = nil
      for i=1,#overlapping do
        if util.get_inserter_lane(overlapping[i], true) == "left" then
          left_inserter = overlapping[i]
          break
        end
      end
      if left_inserter == nil then
        if global.debug then
          game.print("blueprint.filter_miniloaders could not find left inserter")
        end
        left_inserter = overlapping[1]
      end
      if left_inserter ~= overlapping[1]
      and overlapping[1].connections ~= nill
      and next(overlapping[1].connections) then
        -- FIXME: This depends on the first inserter having the external
        -- circuit connections
        local ext_connections = overlapping[1].connections
        overlapping[1].connections = left_inserter.connections
        left_inserter.connections = ext_connections
        for _, bp_entity in ipairs(bp_entities) do
          if bp_entity.connections ~= nil then
            for _, wires in pairs(bp_entity.connections) do
              for wire_type, wire_connections in pairs(wires) do
                for _, connection in ipairs(wire_connections) do
                  if connection.entity_id == overlapping[1].entity_number then
                    connection.entity_id = left_inserter.entity_number
                  elseif connection.entity_id == left_inserter.entity_number then
                    connection.entity_id = overlapping[1].entity_number
                  end
                end
              end
            end
          end
        end
      end
      tag_with_configuration(surface, left_inserter)
      find_slaves(overlapping, left_inserter, to_remove)
      -- FIXME: Is there any guarantee that same position entities will be consecutive?
      i = i + #overlapping
    else
      i = i + 1
    end
  end
  if next(to_remove) then
    remove_entities(bp_entities, to_remove)
    bp.set_blueprint_entities(bp_entities)
  end
end

return M
