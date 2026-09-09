--!nonstrict

local items = {}
local status = "loading"
local errorMessage = ""
local lastUpdated = ""
local isOpen = false

local render

local function syncFromState()
  items = noctalia.state.get("notifications") or {}
  status = noctalia.state.get("status") or "loading"
  errorMessage = noctalia.state.get("error_message") or ""
  lastUpdated = noctalia.state.get("last_updated") or ""
end

local function requestRefresh()
  noctalia.state.set("refresh_request", (noctalia.state.get("refresh_request") or 0) + 1)
end

local function requestMark(action, id)
  noctalia.state.set("mark_request", {
    action = action,
    id = id or "",
    nonce = noctalia.nowMs(),
  })
end

local function openUrl(url)
  if not noctalia.commandExists("xdg-open") then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.xdg_missing"))
    return
  end
  noctalia.runAsync({ "xdg-open", url })
end

local function reasonLabel(reason)
  return noctalia.tr("reason." .. reason)
end

local function typeGlyph(kind)
  if kind == "PullRequest" then
    return "git-pull-request"
  elseif kind == "Issue" then
    return "circle-dot"
  end
  return "bell"
end

local function displayTime(value)
  return (value or ""):gsub("T", " "):gsub("Z$", " UTC")
end

local function notificationRow(item)
  local current = item
  return ui.column({
    key = "notification:" .. current.id,
    gap = 5,
    paddingH = 10,
    paddingV = 8,
    fill = "surface_variant/0.14",
    border = "outline/0.35",
    borderWidth = 1,
    radius = 10,
    align = "stretch",
  }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = typeGlyph(current.type), size = 17, color = "primary" }),
      ui.label({ text = current.repository, fontSize = 12, fontWeight = "bold", color = "primary", flexGrow = 1, maxLines = 1 }),
      ui.label({ text = reasonLabel(current.reason), fontSize = 10, color = "on_surface_variant" }),
      ui.button({
        key = "read:" .. current.id,
        glyph = "check",
        variant = "ghost",
        controlSize = "sm",
        tooltip = noctalia.tr("action.mark_read"),
        enabled = status ~= "marking",
        onClick = function()
          requestMark("one", current.id)
        end,
      }),
    }),
    ui.button({
      key = "open:" .. current.id,
      text = current.title,
      variant = "ghost",
      contentAlign = "start",
      onClick = function()
        openUrl(current.url)
      end,
    }),
    ui.label({ text = displayTime(current.updatedAt), fontSize = 10, color = "on_surface_variant", textAlign = "end" }),
  })
end

local function body()
  if #items > 0 then
    local rows = {}
    for _, item in ipairs(items) do
      table.insert(rows, notificationRow(item))
    end
    return ui.scroll({ flexGrow = 1, gap = 8, align = "stretch" }, rows)
  end

  local message = noctalia.tr("panel.empty")
  local glyph = "checks"
  local color = "primary"
  if status == "loading" then
    message = noctalia.tr("status.loading")
    glyph = "loader"
  elseif status == "marking" then
    message = noctalia.tr("status.marking")
    glyph = "checks"
  elseif status == "error" then
    message = errorMessage ~= "" and errorMessage or noctalia.tr("status.error")
    glyph = "alert-circle"
    color = "error"
  end

  return ui.column({ flexGrow = 1, gap = 10, align = "center", justify = "center" }, {
    ui.glyph({ name = glyph, size = 34, color = color }),
    ui.label({ text = message, color = "on_surface_variant", maxLines = 4, textAlign = "center", maxWidth = 430 }),
  })
end

render = function()
  if not isOpen then
    return
  end

  local header = {
    ui.row({ gap = 8, align = "center", flexGrow = 1 }, {
      ui.glyph({ name = "brand-github", size = 21, color = "primary" }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = tostring(#items), fontSize = 12, color = "primary", fontWeight = "bold" }),
    }),
    ui.button({
      text = noctalia.tr("action.mark_all"),
      glyph = "checks",
      variant = "ghost",
      controlSize = "sm",
      enabled = #items > 0 and status ~= "marking",
      onClick = function()
        requestMark("all")
      end,
    }),
    ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", enabled = status ~= "loading" and status ~= "marking", onClick = requestRefresh }),
    ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("action.settings"), onClick = noctalia.openSettings }),
    ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", onClick = panel.close }),
  }

  local content = {
    ui.row({ gap = 8, align = "center" }, header),
    ui.separator({ thickness = 1, color = "outline/0.35" }),
  }
  if errorMessage ~= "" and #items > 0 then
    table.insert(content, ui.label({ text = errorMessage, fontSize = 11, color = "error", maxLines = 2 }))
  end
  table.insert(content, body())
  if lastUpdated ~= "" then
    table.insert(content, ui.label({ text = noctalia.tr("panel.updated", { time = lastUpdated }), fontSize = 10, color = "on_surface_variant", textAlign = "end" }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch", padding = 4 }, content))
end

noctalia.state.watch("status", function()
  syncFromState()
  render()
end)

function onOpen(_context)
  syncFromState()
  isOpen = true
  render()
end

function onClose()
  isOpen = false
end
