--!nonstrict

local FETCH_TIMEOUT_MS = 30000
local MARK_TIMEOUT_MS = 10000
local DEFAULT_INTERVAL_S = 300
local MIN_INTERVAL_S = 60

local fetching = false
local marking = false
local generation = 0
local markQueue = {}
local markFailures = 0
local lastRefreshNonce = noctalia.state.get("refresh_request") or 0
local lastMarkNonce = 0

local reasonSettings = {
  approval_requested = "show_approval_requested",
  assign = "show_assign",
  author = "show_author",
  ci_activity = "show_ci_activity",
  comment = "show_comment",
  invitation = "show_invitation",
  manual = "show_manual",
  member_feature_requested = "show_member_feature_requested",
  mention = "show_mention",
  review_requested = "show_review_requested",
  security_advisory_credit = "show_security_advisory_credit",
  security_alert = "show_security_alert",
  state_change = "show_state_change",
  subscribed = "show_subscribed",
  team_mention = "show_team_mention",
}

local function readIntervalMs()
  local seconds = tonumber(noctalia.getConfig("refresh_interval")) or DEFAULT_INTERVAL_S
  return math.max(MIN_INTERVAL_S, seconds) * 1000
end

local function publish(items, status, message, updateTimestamp)
  noctalia.state.set("notifications", items)
  noctalia.state.set("count", #items)
  noctalia.state.set("error_message", message or "")
  if updateTimestamp then
    noctalia.state.set("last_updated", noctalia.formatTime("%H:%M"))
  end
  -- Status is the commit marker; consumers reload the complete snapshot here.
  noctalia.state.set("status", status)
end

local function webUrl(apiUrl, repositoryUrl)
  local url = apiUrl
  if type(url) ~= "string" or url == "" then
    url = repositoryUrl or "https://github.com/notifications"
  end
  url = url:gsub("^https://api.github.com/repos/", "https://github.com/")
  url = url:gsub("/pulls/", "/pull/")
  url = url:gsub("/commits/", "/commit/")
  return url
end

local function reasonEnabled(reason)
  local setting = reasonSettings[reason]
  return setting ~= nil and noctalia.getConfig(setting) == true
end

local function normalize(payload)
  local items = {}
  for _, page in ipairs(payload) do
    if type(page) == "table" then
      for _, notification in ipairs(page) do
        if reasonEnabled(notification.reason) then
          local subject = notification.subject or {}
          local repository = notification.repository or {}
          table.insert(items, {
            id = tostring(notification.id or ""),
            reason = notification.reason,
            repository = repository.full_name or "",
            title = subject.title or "",
            type = subject.type or "Notification",
            updatedAt = notification.updated_at or "",
            url = webUrl(subject.url, repository.html_url),
          })
        end
      end
    end
  end
  table.sort(items, function(a, b)
    return a.updatedAt > b.updatedAt
  end)
  return items
end

local function resultError(result)
  if result.timedOut then
    return noctalia.tr("error.timeout")
  end
  if result.exitCode ~= 0 then
    local message = noctalia.string.trim(result.stderr or ""):match("^[^\r\n]+")
    return message or ("gh exited with code " .. tostring(result.exitCode))
  end
  if result.stdoutTruncated then
    return noctalia.tr("error.truncated")
  end
  return nil
end

local startFetch

startFetch = function()
  if fetching or marking then
    return
  end
  if not noctalia.commandExists("gh") then
    publish(noctalia.state.get("notifications") or {}, "error", noctalia.tr("error.gh_missing"), false)
    return
  end

  fetching = true
  generation += 1
  local thisGeneration = generation
  noctalia.state.set("error_message", "")
  noctalia.state.set("status", "loading")

  local started = noctalia.runAsync({
    "gh", "api", "notifications?per_page=50", "--paginate", "--slurp",
  }, function(result)
    if thisGeneration ~= generation then
      return
    end
    fetching = false

    local err = resultError(result)
    if err then
      publish(noctalia.state.get("notifications") or {}, "error", err, false)
      return
    end

    local decoded = noctalia.json.decode(result.stdout or "")
    if type(decoded) ~= "table" then
      publish(noctalia.state.get("notifications") or {}, "error", noctalia.tr("error.parse"), false)
      return
    end
    publish(normalize(decoded), "ok", "", true)
  end, FETCH_TIMEOUT_MS)

  if not started then
    fetching = false
    publish(noctalia.state.get("notifications") or {}, "error", noctalia.tr("error.start"), false)
  end
end

local function markNext()
  if #markQueue == 0 then
    marking = false
    if markFailures > 0 then
      noctalia.notifyError(noctalia.tr("title"), noctalia.tr("error.mark_failed"))
    end
    startFetch()
    return
  end

  local item = table.remove(markQueue, 1)
  local started = noctalia.runAsync({
    "gh", "api", "--method", item.method, "notifications/threads/" .. item.id,
  }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      markFailures += 1
      noctalia.log("github-notifications: failed to update thread " .. item.id)
    end
    markNext()
  end, MARK_TIMEOUT_MS)

  if not started then
    markFailures += 1
    markNext()
  end
end

local function markNotifications(request)
  if marking or type(request) ~= "table" then
    return
  end

  local current = noctalia.state.get("notifications") or {}
  local queue = {}
  local remaining = {}
  for _, item in ipairs(current) do
    local selected = request.action == "all"
      or ((request.action == "one" or request.action == "done") and item.id == request.id)
    if selected then
      table.insert(queue, {
        id = item.id,
        method = request.action == "done" and "DELETE" or "PATCH",
      })
    else
      table.insert(remaining, item)
    end
  end
  if #queue == 0 then
    return
  end

  if fetching then
    generation += 1
    fetching = false
  end
  marking = true
  markQueue = queue
  markFailures = 0
  publish(remaining, "marking", "", false)
  markNext()
end

noctalia.setUpdateInterval(readIntervalMs())

if noctalia.state.get("status") == nil then
  noctalia.state.set("last_updated", "")
  publish({}, "loading", "", false)
end

noctalia.state.watch("refresh_request", function(value)
  local nonce = tonumber(value) or 0
  if nonce ~= lastRefreshNonce then
    lastRefreshNonce = nonce
    startFetch()
  end
end)

noctalia.state.watch("mark_request", function(request)
  local nonce = type(request) == "table" and tonumber(request.nonce) or 0
  if nonce ~= 0 and nonce ~= lastMarkNonce then
    lastMarkNonce = nonce
    markNotifications(request)
  end
end)

startFetch()

function update()
  startFetch()
end

function onConfigChanged()
  noctalia.setUpdateInterval(readIntervalMs())
  startFetch()
end

function onIpc(event, _payload)
  if event == "refresh" then
    startFetch()
  elseif event == "mark-all" then
    markNotifications({ action = "all" })
  elseif event == "dump" then
    local summary = {
      status = noctalia.state.get("status"),
      count = noctalia.state.get("count") or 0,
      error = noctalia.state.get("error_message") or "",
    }
    noctalia.log("github-notifications: " .. (noctalia.json.encode(summary) or "?"))
  end
end
