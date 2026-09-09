--!nonstrict

local count = noctalia.state.get("count") or 0
local status = noctalia.state.get("status") or "loading"
local lastUpdated = noctalia.state.get("last_updated") or ""

local function render()
  if status == "error" then
    barWidget.setGlyph("alert-circle")
  else
    barWidget.setGlyph(count > 0 and "brand-github-filled" or "brand-github")
  end
  barWidget.setText(count > 0 and tostring(count) or "")
  barWidget.setGlyphColor(status == "error" and "error" or (count > 0 and "primary" or "on_surface_variant"))

  local tooltip = noctalia.trp("widget.unread", count, { count = count })
  if status == "loading" then
    tooltip = tooltip .. "\n" .. noctalia.tr("status.loading")
  elseif status == "marking" then
    tooltip = tooltip .. "\n" .. noctalia.tr("status.marking")
  elseif status == "error" then
    tooltip = tooltip .. "\n" .. noctalia.tr("status.error")
  elseif lastUpdated ~= "" then
    tooltip = tooltip .. "\n" .. noctalia.tr("widget.updated", { time = lastUpdated })
  end
  tooltip = tooltip .. "\n" .. noctalia.tr("widget.settings_hint")
  barWidget.setTooltip(tooltip)
  barWidget.setVisible(true)
end

noctalia.state.watch("status", function()
  count = noctalia.state.get("count") or 0
  status = noctalia.state.get("status") or "loading"
  lastUpdated = noctalia.state.get("last_updated") or ""
  render()
end)

function onClick()
  noctalia.togglePanel("tejo/github-notifications:notifications")
end

function onRightClick()
  noctalia.openSettings()
end

render()
