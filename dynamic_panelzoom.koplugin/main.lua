local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local PanelViewer = require("panel_viewer")
local _ = require("gettext")
local logger = require("logger")
local util = require("util")
local json = require("json")

-- =============================================================================
-- Performance tracing
--
-- Every press opens a trace, and everything it sets off -- page turn, panel
-- analysis, MuPDF render, screen paint -- is timed against that trace, so the
-- log says exactly where a slow "next" went. Presses that arrive while a trace
-- is still running are logged as QUEUED together with the guard that swallowed
-- them and how long that guard had been up, which is what makes a press look
-- ignored.
--
-- Grep the KOReader log for "DPZPERF": one block per press, ending in a TOTAL
-- line with a breakdown of every span inside it.
--     BEGIN   trace opened by a press
--       .     point-in-time note, stamped with time since the press
--       +     completed span, with its duration
--       ~     background/untraced note
--     TOTAL   trace closed: press -> panel on screen
-- =============================================================================

local now_ms
do
    -- ui/time is the current KOReader clock; ffi/util.gettime() is the
    -- long-lived fallback for older builds. os.clock() is CPU time, not wall
    -- time, so it is only a last resort.
    local ok_time, time = pcall(require, "ui/time")
    if ok_time and type(time) == "table" and time.now and time.to_ms then
        now_ms = function() return time.to_ms(time.now()) end
    else
        local ok_ffi, ffiutil = pcall(require, "ffi/util")
        if ok_ffi and type(ffiutil) == "table" and ffiutil.gettime then
            now_ms = function()
                local sec, usec = ffiutil.gettime()
                return sec * 1000 + usec / 1000
            end
        else
            now_ms = function() return os.clock() * 1000 end
        end
    end
end

local Perf = {
    -- Tracing is a debugging aid, off by default: every press otherwise writes a
    -- multi-line DPZPERF block to the log. Flip it on from the menu (persisted as
    -- dpz_perf_tracing) when a slow "next" needs diagnosing. When disabled, the
    -- logging methods below early-return; only the cheap mark()/elapsed() clock
    -- helpers keep working, since callers hold their marks unconditionally.
    enabled = false,
    seq = 0,
    _start = nil,  -- ms at which the open trace began
    _label = nil,  -- what the user did to open it
    _steps = nil,  -- ordered span summaries for the TOTAL line
}

-- Timestamp to measure a span against: local t = Perf:mark()
function Perf:mark()
    return now_ms()
end

-- Milliseconds since a mark (0 if the mark was never taken).
function Perf:elapsed(t0)
    if not t0 then return 0 end
    return now_ms() - t0
end

function Perf:isOpen()
    return self._start ~= nil
end

function Perf:_prefix()
    if not self._start then return "DPZPERF [-]" end
    return string.format("DPZPERF [%d]", self.seq)
end

-- Open a trace. Everything logged until finish() is attributed to it.
function Perf:begin(label, fmt, ...)
    if not self.enabled then return end
    if self._start then
        logger.warn(string.format("%s ORPHAN: '%s' never finished, opened %.0f ms ago",
            self:_prefix(), self._label or "?", self:elapsed(self._start)))
    end
    self.seq = self.seq + 1
    self._start = now_ms()
    self._label = label
    self._steps = {}
    logger.info(string.format("%s BEGIN %s %s", self:_prefix(), label,
        fmt and string.format(fmt, ...) or ""))
end

-- Point-in-time note, stamped with how long the open trace has been running.
function Perf:event(fmt, ...)
    if not self.enabled then return end
    logger.info(string.format("%s   . %s (+%.0f ms)", self:_prefix(),
        string.format(fmt, ...), self:elapsed(self._start)))
end

-- Note not tied to a trace: background work with no press waiting on it.
function Perf:note(fmt, ...)
    if not self.enabled then return end
    logger.info(string.format("%s   ~ %s", self:_prefix(), string.format(fmt, ...)))
end

-- Record a completed span. Returns its duration so callers can reuse it.
function Perf:step(name, t0, fmt, ...)
    if not self.enabled then return end
    local ms = self:elapsed(t0)
    logger.info(string.format("%s   + %-24s %8.1f ms  %s", self:_prefix(), name, ms,
        fmt and string.format(fmt, ...) or ""))
    if self._steps then
        table.insert(self._steps, string.format("%s %.0f", name, ms))
    end
    return ms
end

-- Close the trace with the press -> pixels total and a one-line breakdown.
function Perf:finish(fmt, ...)
    if not self._start then return end
    local total = self:elapsed(self._start)
    logger.info(string.format("%s TOTAL %s %.1f ms %s | %s", self:_prefix(),
        self._label or "?", total, fmt and string.format(fmt, ...) or "",
        table.concat(self._steps or {}, " | ")))
    self._start, self._label, self._steps = nil, nil, nil
    return total
end

-- Drop an open trace without a TOTAL line (viewer closed mid-flight).
function Perf:abandon(reason)
    if not self._start then return end
    logger.info(string.format("%s ABANDONED %s after %.0f ms: %s", self:_prefix(),
        self._label or "?", self:elapsed(self._start), reason or ""))
    self._start, self._label, self._steps = nil, nil, nil
end

local PanelZoomIntegration = WidgetContainer:extend{
    name = "dynamic_panelzoom",
    integration_mode = false,
    current_panels = {},
    current_panel_index = 1,
    last_page_seen = -1,
    tap_navigation_enabled = true,
    tap_zones = { left = 0.3, right = 0.7 },
    _panel_cache = {}, -- Cache JSON per document
    _preloaded_image = nil, -- Pre-rendered next panel
    _preloaded_panel_index = nil, -- Index of preloaded panel
    _is_switching = false, -- Debounce guard to prevent fast tap issues
    _is_changing_page = false, -- True while a page change is in progress
    _page_change_diff = nil, -- Direction of current page change (+1 or -1)
    _original_panel_zoom_handler = nil, -- Store original panel zoom handler
    _original_ocr_handler = nil, -- Store original OCR handler
    _original_ocr_menu_enabled = nil, -- Store original OCR menu state
    _original_genPanelZoomMenu = nil, -- Store original panel zoom menu function
    _json_available = false, -- Track if JSON is available for current document
    reading_direction_override = nil, -- User override for reading direction (rtl/ltr)
    zoom_margin_percent = 0.05, -- Default 5% extra margin for the free zoom mode
    standard_margin_percent = 0.0, -- Default 0% extra margin for standard panel-by-panel navigation
    show_adjacent_panels = true,   -- Show adjacent content (Smart Fill)
    zoom_initial_scale = 1.2, -- Default 1.2x initial software scale for the free zoom mode
    panelzoom_tap_forward_zone = "auto", -- auto, left, or right

    -- --- Screen refresh (E-Ink ghosting) ---
    full_refresh_every = 6,        -- flash every N panel draws; 0 = never
    flash_on_page_turn = true,     -- always flash when crossing a page boundary
    _panels_since_flash = 0,

    -- --- Row view ---
    row_mode = "panel",            -- "panel" | "row" | "two_rows" | "auto"
    row_mode_landscape_only = true,
    row_overlap_ratio = 0.5,       -- vertical overlap needed to call two panels one row

    -- --- Cross-page row pairing ---
    -- When a page ends on a lonely single row (two_rows/auto), pull the first row
    -- of the next page up to fill the empty half instead of showing it alone.
    cross_page_rows = true,
    -- ...but only when the leftover row (and the row pulled up) are genuinely
    -- SHORT -- i.e. leave an empty half to fill. Comic detection often merges a
    -- whole grid into one tall "row" (0.7-1.0 of the page); pairing two of those
    -- crams ~two pages onto one screen. A real comic row is ~0.2-0.35 of the
    -- page, so a row taller than this fraction is treated as full-height and
    -- shown alone, never paired. This also stops a full-page cover from starting
    -- a runaway offset cascade through the whole book.
    cross_page_max_row_frac = 0.5,
}

function PanelZoomIntegration:init()
    self.experimental_panel_sorting_enabled = false

    -- Per-page count of leading rows already shown as part of the previous page's
    -- cross-page composite, so arriving at that page skips them. Keyed by page
    -- number; only meaningful while navigating a boundary linearly (reset on any
    -- manual jump, rotation, or layout change). See maybeMarkCrossPageComposite.
    self._row_offsets = {}

    -- Auto-detect JSON and integrate with Panel Zoom when document is opened
    self.onDocumentLoaded = function()
        self:checkAndIntegratePanelZoom()
    end
    
    -- Page change handler: event-driven panel transitions
    -- KOReader dispatches PageUpdate as: handler(self, new_page_no, orig_mode)
    -- When _is_changing_page is true, the event was triggered by our changePage()
    -- call to onGotoViewRel(), so we handle the panel transition.
    -- Otherwise it's a normal page change (user swipe, menu, etc.)
    self.onPageUpdate = function(_, new_page_no)
        if self._is_changing_page then
            -- Time from our onGotoViewRel() call to KOReader announcing the new
            -- page: the part of a page turn we do not control.
            Perf:step("PageUpdate arrived", self._page_change_started_at,
                "page=%s", tostring(new_page_no))
            self:_onPageChangeComplete(new_page_no)
        else
            Perf:note("PageUpdate not ours (page=%s), re-checking integration",
                tostring(new_page_no))
            -- A manual jump (swipe, menu, skim) invalidates the cross-page row
            -- bookkeeping: offsets are only valid when the boundary is crossed
            -- linearly through our own navigation.
            self._row_offsets = {}
            local t0 = Perf:mark()
            self:checkAndIntegratePanelZoom()
            Perf:note("checkAndIntegratePanelZoom took %.0f ms", Perf:elapsed(t0))
        end
    end
    
    -- Optional: Re-render current panel if document settings change
    self.onSettingsUpdate = function()
        if self._current_imgviewer and self.integration_mode then
            logger.info("PanelZoom: Settings changed, refreshing current panel")
            self:displayCurrentPanel()
        end
    end
    
    -- Restore persisted settings
    if G_reader_settings then
        self.full_refresh_every = G_reader_settings:readSetting("dpz_full_refresh_every")
            or self.full_refresh_every
        self.flash_on_page_turn = G_reader_settings:nilOrTrue("dpz_flash_on_page_turn")
        self.row_mode = G_reader_settings:readSetting("dpz_row_mode") or self.row_mode
        self.row_mode_landscape_only = G_reader_settings:nilOrTrue("dpz_row_landscape_only")
        self.cross_page_rows = G_reader_settings:nilOrTrue("dpz_cross_page_rows")
        Perf.enabled = G_reader_settings:isTrue("dpz_perf_tracing")
    end

    -- Rotating changes which packing is optimal, so rebuild units and stay put.
    self.onSetRotationMode = function()
        if not self.integration_mode or not self._current_imgviewer then return end
        -- Packing changes with orientation, so the boundary bookkeeping is stale.
        self._row_offsets = {}
        local old = self.current_panels[self.current_panel_index]
        self:importToggleZoomPanels()
        if old and #self.current_panels > 0 then
            local best, best_d = 1, math.huge
            for i, u in ipairs(self.current_panels) do
                local d = math.abs((u.y + u.h / 2) - (old.y + old.h / 2))
                if d < best_d then best, best_d = i, d end
            end
            self.current_panel_index = best
        end
        self.current_panel_index = math.min(self.current_panel_index, math.max(#self.current_panels, 1))
        self:cleanupPreloadedImage()
        self:_forceFullRefreshNext()
        self:displayCurrentPanel()
    end

    -- Integrate with existing panel zoom menu
    self:setupPanelZoomMenuIntegration()
end

-- =============================================================================
-- Screen refresh control
--
-- Upstream never emits a flashing refresh: PanelViewer:update() used "ui", and
-- _onPageChangeComplete() called avoidFlashOnNextRepaint(). Neither "ui" nor
-- "fast" feeds KOReader's partial->full promotion counter, so the built-in
-- "full refresh rate" setting could never fire while the panel viewer was up.
-- We now count draws ourselves and ask for "full" on our own schedule.
-- =============================================================================

function PanelZoomIntegration:_panelRefreshMode()
    local every = self.full_refresh_every or 0
    if every <= 0 then
        self._panels_since_flash = 0
        return "partial"
    end
    self._panels_since_flash = (self._panels_since_flash or 0) + 1
    if self._panels_since_flash >= every then
        self._panels_since_flash = 0
        logger.info("DynamicPanelZoom: forcing full (flashing) refresh")
        return "full"
    end
    return "partial"
end

-- Make the next draw flash, if flashing is enabled at all.
function PanelZoomIntegration:_forceFullRefreshNext()
    if (self.full_refresh_every or 0) > 0 then
        self._panels_since_flash = self.full_refresh_every
    end
end

-- =============================================================================
-- Row grouping
--
-- analyzePageForPanels() already sorts panels top-to-bottom and then by reading
-- direction within a row, so same-row panels are adjacent in the array and a
-- single greedy pass is enough to merge them.
-- =============================================================================

function PanelZoomIntegration:groupPanelsIntoRows(panels, overlap_ratio)
    if #panels == 0 then return {} end
    overlap_ratio = overlap_ratio or self.row_overlap_ratio or 0.5

    -- Cluster panels into rows by their TOP edge against a fixed per-row
    -- reference, NOT against the row's growing bounding box. The old overlap-vs-
    -- accumulated-bbox test chained whole visual rows into one giant "row"
    -- whenever a tall panel (one spanning two rows, or a merged-gutter blob)
    -- stretched the box down far enough to swallow the row below it -- which
    -- then showed 3-4 rows at once instead of two. Comparing each panel's top to
    -- the row's first (topmost) panel means a tall panel joins its own row and
    -- extends it downward without dragging in the next row.
    local heights = {}
    for _, p in ipairs(panels) do heights[#heights + 1] = p.h end
    table.sort(heights)
    local median_h = heights[math.ceil(#heights / 2)] or 0.2
    local tol = overlap_ratio * median_h   -- same-row if tops are within this

    -- Order strictly by top edge so the reference is always the row's topmost.
    local by_top = {}
    for _, p in ipairs(panels) do by_top[#by_top + 1] = p end
    table.sort(by_top, function(a, b) return a.y < b.y end)

    local rows = {}
    local ref_top
    for _, p in ipairs(by_top) do
        if #rows == 0 or (p.y - ref_top) > tol then
            table.insert(rows, { x = p.x, y = p.y, w = p.w, h = p.h, panels = 1 })
            ref_top = p.y   -- fixed for this row; never grows
        else
            local row = rows[#rows]
            local x2 = math.max(row.x + row.w, p.x + p.w)
            local y2 = math.max(row.y + row.h, p.y + p.h)
            row.x = math.min(row.x, p.x)
            row.y = math.min(row.y, p.y)
            row.w = x2 - row.x
            row.h = y2 - row.y
            row.panels = row.panels + 1
        end
    end
    return rows
end

function PanelZoomIntegration:packRows(rows, mode, dim)
    local max_rows = math.huge
    if mode == "row" then
        max_rows = 1
    elseif mode == "two_rows" then
        max_rows = 2
    end

    -- Fraction of the screen a block of this shape will actually fill once
    -- scaled to fit. Maximal when the block's aspect matches the screen's.
    local screen_aspect = Screen:getWidth() / Screen:getHeight()
    local function utilisation(w_frac, h_frac)
        local a = (w_frac * dim.w) / (h_frac * dim.h)
        return math.min(a, screen_aspect) / math.max(a, screen_aspect)
    end

    local units, i = {}, 1
    while i <= #rows do
        local u = { x = rows[i].x, y = rows[i].y, w = rows[i].w, h = rows[i].h, rows = 1 }
        local j = i + 1
        while j <= #rows and u.rows < max_rows do
            local r = rows[j]
            local nx = math.min(u.x, r.x)
            local ny = math.min(u.y, r.y)
            local nw = math.max(u.x + u.w, r.x + r.w) - nx
            local nh = math.max(u.y + u.h, r.y + r.h) - ny
            if mode == "auto" then
                -- Take the next row only while doing so fills MORE of the screen.
                -- A single wide row is width-limited and wastes vertical space;
                -- stacking rows trades zoom for coverage until it overshoots.
                if utilisation(nw, nh) <= utilisation(u.w, u.h) then break end
            end
            u.x, u.y, u.w, u.h = nx, ny, nw, nh
            u.rows = u.rows + 1
            j = j + 1
        end
        table.insert(units, u)
        i = j
    end
    return units
end

-- Raw detected panels for ANY page, cache-backed with the same key layout as
-- importToggleZoomPanels (doc -> reading_dir -> page). This is what lets a
-- composite reach into the next page: its analysis is paid once and reused.
function PanelZoomIntegration:getRawPanelsForPage(page_idx)
    local doc_path = self.ui.document.file
    if not doc_path then return {} end
    local reading_dir = self:getEffectiveReadingDirection()
    if not self._panel_cache[doc_path] then self._panel_cache[doc_path] = {} end
    if not self._panel_cache[doc_path][reading_dir] then self._panel_cache[doc_path][reading_dir] = {} end

    local raw = self._panel_cache[doc_path][reading_dir][page_idx]
    if not raw then
        if self.experimental_panel_sorting_enabled then
            raw = self:analyzePageForPanelsExperimental(page_idx)
        else
            raw = self:analyzePageForPanels(page_idx)
        end
        self._panel_cache[doc_path][reading_dir][page_idx] = raw
    end
    return raw
end

-- Rows (merged panels) for any page, in reading order top-to-bottom.
function PanelZoomIntegration:getPageRows(page_idx)
    local raw = self:getRawPanelsForPage(page_idx)
    if #raw == 0 then return {} end
    return self:groupPanelsIntoRows(raw)
end

-- Turn cached raw panels into what we actually navigate through.
function PanelZoomIntegration:buildViewUnits(raw_panels, page_idx)
    local mode = self.row_mode or "panel"
    if mode == "panel" or #raw_panels == 0 then return raw_panels end
    if self.row_mode_landscape_only and Screen:getWidth() <= Screen:getHeight() then
        return raw_panels
    end
    local dim = self.ui.document:getNativePageDimensions(page_idx)
    if not dim then return raw_panels end

    local rows = self:groupPanelsIntoRows(raw_panels)

    -- Drop leading rows already shown as part of the previous page's composite.
    local offset = self._row_offsets[page_idx] or 0
    if offset > 0 then
        local trimmed = {}
        for i = offset + 1, #rows do trimmed[#trimmed + 1] = rows[i] end
        rows = trimmed
    end

    local units = self:packRows(rows, mode, dim)

    -- If this page ends on a lonely single row, flag the last unit so it can pull
    -- the first row of the next page. Only a cheap page-bound check happens here;
    -- the next page is analyzed lazily (preload/render) via resolveComposite.
    self:maybeMarkCrossPageComposite(units, page_idx, dim, mode)

    logger.info(string.format(
        "DynamicPanelZoom: row mode '%s' - %d panels -> %d rows -> %d view units (offset %d)",
        mode, #raw_panels, #rows, #units, offset))
    return units
end

-- Flag a lonely trailing row so it becomes a cross-page composite. No analysis of
-- the next page here -- that is deferred to resolveComposite so page entry stays
-- cheap; this only decides intent.
function PanelZoomIntegration:maybeMarkCrossPageComposite(units, page_idx, dim, mode)
    if not self.cross_page_rows then return end
    if mode ~= "two_rows" and mode ~= "auto" then return end
    if #units == 0 then return end

    local last = units[#units]
    if (last.rows or 1) ~= 1 then return end
    -- In auto mode a page that is a single unit is not a "leftover" to fill.
    if mode == "auto" and #units < 2 then return end
    -- Only pair a genuinely short leftover row: a tall "row" (a merged grid or a
    -- big/splash panel) already fills the screen, so pairing it just crams two
    -- pages together. See cross_page_max_row_frac.
    if (last.h or 1) > (self.cross_page_max_row_frac or 0.5) then return end

    local page_count = self.ui.document.getPageCount and self.ui.document:getPageCount() or nil
    if page_count and page_idx + 1 > page_count then return end

    last.composite = true
    last.resolved = false
    last.next_page = page_idx + 1
    last.first_page = page_idx
    last.first_dim = dim
    last.first_rect = { x = last.x, y = last.y, w = last.w, h = last.h }
end

-- Resolve a flagged composite by analyzing the next page and taking its first
-- row. Idempotent. On any miss (last page, empty next page) the unit is
-- downgraded to a normal lonely row. Sets the next page's row offset so arriving
-- there skips the row shown here.
function PanelZoomIntegration:resolveComposite(unit)
    if not unit or not unit.composite or unit.resolved then return end
    unit.resolved = true

    local page_count = self.ui.document.getPageCount and self.ui.document:getPageCount() or nil
    local next_idx = unit.next_page
    if not next_idx or (page_count and next_idx > page_count) then
        unit.composite = false
        return
    end

    local next_rows = self:getPageRows(next_idx)
    if #next_rows == 0 then
        unit.composite = false
        return
    end
    local next_dim = self.ui.document:getNativePageDimensions(next_idx)
    if not next_dim then
        unit.composite = false
        return
    end

    local nr = next_rows[1]
    -- Don't pull up a tall next-page row either: stacking two full-height rows
    -- crams two pages onto one screen. Show the leftover alone instead.
    if (nr.h or 1) > (self.cross_page_max_row_frac or 0.5) then
        unit.composite = false
        return
    end
    unit.parts = {
        { page = unit.first_page, dim = unit.first_dim,
          rect = { x = unit.first_rect.x, y = unit.first_rect.y,
                   w = unit.first_rect.w, h = unit.first_rect.h } },
        { page = next_idx, dim = next_dim,
          rect = { x = nr.x, y = nr.y, w = nr.w, h = nr.h } },
    }
    self._row_offsets[next_idx] = 1
    logger.info(string.format(
        "DynamicPanelZoom: composite on page %d pulls row 1 of page %d",
        unit.first_page, next_idx))
end

-- Get effective reading direction (override takes precedence over JSON)
function PanelZoomIntegration:getEffectiveReadingDirection()
    -- No longer use a non-existent JSON property. Default is ltr unless overridden.
    if self.reading_direction_override then
        return self.reading_direction_override
    end
    return "ltr"
end

-- Check if document is compatible and integrate with Panel Zoom automatically
function PanelZoomIntegration:checkAndIntegratePanelZoom()
    if not self.ui.document then return end
    
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    -- Dynamic Panel Zoom is always available, we just integrate it
    self._json_available = true -- we fake it to keep the integration flag happy
    self:integrateWithPanelZoom()
    logger.info("DynamicPanelZoom: Auto-integration enabled")
end

-- Integrate with built-in Panel Zoom
function PanelZoomIntegration:integrateWithPanelZoom()
    if not self.ui.highlight then return end
    
    -- Store the original handler if not already stored
    if not self._original_panel_zoom_handler then
        self._original_panel_zoom_handler = self.ui.highlight.onPanelZoom
    end
    
    -- Store the original panel zoom enabled state
    if self._original_panel_zoom_enabled == nil then
        self._original_panel_zoom_enabled = self.ui.highlight.panel_zoom_enabled
    end
    
    -- Override Panel Zoom to use our JSON when available
    self.ui.highlight.onPanelZoom = function(inst, arg, ges)
        return self:onIntegratedPanelZoom(arg, ges)
    end
    
    self.integration_mode = true
    if self.ui.highlight then self.ui.highlight.panel_zoom_enabled = true end
    
    -- Block OCR when Panel Zoom integration is active
    self:blockOCR()
end

-- Restore original Panel Zoom behavior
function PanelZoomIntegration:restoreOriginalPanelZoom()
    if not self.ui.highlight then return end
    
    -- Restore the original handler
    if self._original_panel_zoom_handler then
        self.ui.highlight.onPanelZoom = self._original_panel_zoom_handler
    else
        self.ui.highlight.onPanelZoom = nil
    end
    
    -- Restore the original panel zoom enabled state
    if self._original_panel_zoom_enabled ~= nil then
        self.ui.highlight.panel_zoom_enabled = self._original_panel_zoom_enabled
    end
    
    self.integration_mode = false
    
    -- Restore OCR when Panel Zoom integration is disabled
    self:restoreOCR()
    
    -- Restore original panel zoom menu
    self:restorePanelZoomMenu()
end

-- Block OCR functionality when Panel Zoom is active
function PanelZoomIntegration:blockOCR()
    -- Store original OCR handler if not already stored
    if not self._original_ocr_handler and self.ui.ocr then
        self._original_ocr_handler = self.ui.ocr.onOCRText
    end
    
    -- Disable OCR by replacing the handler with a no-op function
    if self.ui.ocr then
        self.ui.ocr.onOCRText = function()
            logger.info("DynamicPanelZoom: OCR blocked - Panel Zoom integration is active")
            return false
        end
        logger.info("DynamicPanelZoom: OCR functionality blocked")
    end
    
    -- Also disable OCR menu items if available
    if self.ui.menu and self.ui.menu.ocr_menu then
        self._original_ocr_menu_enabled = self.ui.menu.ocr_menu.enabled
        self.ui.menu.ocr_menu.enabled = false
        logger.info("DynamicPanelZoom: OCR menu items disabled")
    end
end

-- Restore OCR functionality when Panel Zoom is disabled
function PanelZoomIntegration:restoreOCR()
    -- Guard against multiple restoration calls
    if not self._original_ocr_handler and (self._original_ocr_menu_enabled == nil) then
        return -- Already restored or never stored
    end
    
    -- Restore original OCR handler
    if self.ui.ocr and self._original_ocr_handler then
        self.ui.ocr.onOCRText = self._original_ocr_handler
        self._original_ocr_handler = nil
        logger.info("DynamicPanelZoom: OCR functionality restored")
    end
    
    -- Restore OCR menu items
    if self.ui.menu and self.ui.menu.ocr_menu and self._original_ocr_menu_enabled ~= nil then
        self.ui.menu.ocr_menu.enabled = self._original_ocr_menu_enabled
        self._original_ocr_menu_enabled = nil
        logger.info("DynamicPanelZoom: OCR menu items restored")
    end
end

-- Callback methods for PanelViewer
-- Record a press we cannot act on yet, and say which guard swallowed it.
-- This is the line to look for when navigation feels like it needs several
-- presses: it names the blocker and how long it had already been up.
function PanelZoomIntegration:_notePressQueued(dir)
    self._pending_nav = dir
    self._pending_nav_count = (self._pending_nav_count or 0) + 1
    if self._pending_nav_count == 1 then
        self._pending_nav_at = Perf:mark()
    end
    local why = {}
    if self._is_switching then
        table.insert(why, string.format("tap debounce up for %.0f ms",
            Perf:elapsed(self._switch_started_at)))
    end
    if self._is_changing_page then
        table.insert(why, string.format("page change in flight for %.0f ms",
            Perf:elapsed(self._page_change_started_at)))
    end
    Perf:event("PRESS '%s' QUEUED, not acted on now (%d press(es) queued since the last handled one) -- %s",
        dir, self._pending_nav_count, table.concat(why, ", "))
end

-- Spatial navigation methods for PanelViewer
function PanelZoomIntegration:handleTapRight()
    if self._is_switching or self._is_changing_page then
        -- Remember the tap instead of discarding it. Row mode means fewer units
        -- per page, so a much larger share of taps land on a page boundary and
        -- hit the changePage dead window; silently dropping them reads as
        -- "I have to press next several times".
        self:_notePressQueued("right")
        return
    end
    Perf:begin("tap-right", "panel %d/%d, page %d%s", self.current_panel_index,
        #self.current_panels, self.last_page_seen or -1,
        self._replaying_nav and " (REPLAY of a queued press)" or "")
    self._pending_nav = nil
    self._pending_nav_count = 0
    self._pending_nav_at = nil
    self._is_switching = true
    self._switch_started_at = Perf:mark()
    UIManager:scheduleIn(0.3, function()
        self._is_switching = false
        self._switch_started_at = nil
        self:_flushPendingNav()
    end)
    
    local tap_forward_zone = self.panelzoom_tap_forward_zone or "auto"
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    logger.info(string.format("DynamicPanelZoom: handleTapRight index=%d, is_rtl=%s, reading_dir=%s", 
        self.current_panel_index, tostring(is_rtl), reading_dir))
    
    local intent_forward = false
    if tap_forward_zone == "right" then
        intent_forward = true
    elseif tap_forward_zone == "left" then
        intent_forward = false
    else
        intent_forward = not is_rtl
    end
    
    if intent_forward then
        -- Forward Flow
        -- Check preload first for Next
        if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
            logger.info("PanelZoom: Using preloaded panel for instant switch (Forward)")
            Perf:event("next panel was preloaded -> instant switch")
            self.current_panel_index = self.current_panel_index + 1
            self:displayPreloadedPanel()
            Perf:finish("preloaded panel shown")
            return
        end

        if self.current_panel_index < #self.current_panels then
            Perf:event("next panel NOT preloaded -> rendering it now, on the input thread")
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
            Perf:finish("panel %d/%d", self.current_panel_index, #self.current_panels)
        else
            -- End of page, go to next page
            logger.info("PanelZoom: End of page reached, jumping to next page")
            Perf:event("END OF PAGE (panel %d of %d) -> full page turn, nothing for the next page is preloaded",
                self.current_panel_index, #self.current_panels)
            self:changePage(1)
            -- Trace stays open: _onPageChangeComplete() closes it.
        end
    else
        -- Backward Flow
        if self.current_panel_index > 1 then
            Perf:event("stepping back inside the page (preload only ever covers the next panel)")
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
            Perf:finish("panel %d/%d", self.current_panel_index, #self.current_panels)
        else
            -- Top of page reached, go to previous page
            logger.info("PanelZoom: Top of page reached, jumping to previous page")
            Perf:event("TOP OF PAGE -> full page turn backwards")
            self:changePage(-1)
            -- Trace stays open: _onPageChangeComplete() closes it.
        end
    end
end

function PanelZoomIntegration:handleTapLeft()
    if self._is_switching or self._is_changing_page then
        -- Remember the tap instead of discarding it. Row mode means fewer units
        -- per page, so a much larger share of taps land on a page boundary and
        -- hit the changePage dead window; silently dropping them reads as
        -- "I have to press next several times".
        self:_notePressQueued("left")
        return
    end
    Perf:begin("tap-left", "panel %d/%d, page %d%s", self.current_panel_index,
        #self.current_panels, self.last_page_seen or -1,
        self._replaying_nav and " (REPLAY of a queued press)" or "")
    self._pending_nav = nil
    self._pending_nav_count = 0
    self._pending_nav_at = nil
    self._is_switching = true
    self._switch_started_at = Perf:mark()
    UIManager:scheduleIn(0.3, function()
        self._is_switching = false
        self._switch_started_at = nil
        self:_flushPendingNav()
    end)
    
    local tap_forward_zone = self.panelzoom_tap_forward_zone or "auto"
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    logger.info(string.format("DynamicPanelZoom: handleTapLeft index=%d, is_rtl=%s, reading_dir=%s", 
        self.current_panel_index, tostring(is_rtl), reading_dir))
    
    local intent_forward = false
    if tap_forward_zone == "left" then
        intent_forward = true
    elseif tap_forward_zone == "right" then
        intent_forward = false
    else
        intent_forward = is_rtl
    end
    
    if intent_forward then
        -- Forward Flow
        -- Check preload first for Next
        if self._preloaded_image and self._preloaded_panel_index == self.current_panel_index + 1 then
            logger.info("PanelZoom: Using preloaded panel for instant switch (Forward)")
            Perf:event("next panel was preloaded -> instant switch")
            self.current_panel_index = self.current_panel_index + 1
            self:displayPreloadedPanel()
            Perf:finish("preloaded panel shown")
            return
        end

        if self.current_panel_index < #self.current_panels then
            Perf:event("next panel NOT preloaded -> rendering it now, on the input thread")
            self.current_panel_index = self.current_panel_index + 1
            self:displayCurrentPanel()
            Perf:finish("panel %d/%d", self.current_panel_index, #self.current_panels)
        else
            -- End of page, go to next page
            logger.info("PanelZoom: End of page reached, jumping to next page")
            Perf:event("END OF PAGE (panel %d of %d) -> full page turn, nothing for the next page is preloaded",
                self.current_panel_index, #self.current_panels)
            self:changePage(1)
            -- Trace stays open: _onPageChangeComplete() closes it.
        end
    else
        -- Backward Flow
        if self.current_panel_index > 1 then
            Perf:event("stepping back inside the page (preload only ever covers the next panel)")
            self.current_panel_index = self.current_panel_index - 1
            self:displayCurrentPanel()
            Perf:finish("panel %d/%d", self.current_panel_index, #self.current_panels)
        else
            -- Top of page reached, go to previous page
            logger.info("PanelZoom: Top of page reached, jumping to previous page")
            Perf:event("TOP OF PAGE -> full page turn backwards")
            self:changePage(-1)
            -- Trace stays open: _onPageChangeComplete() closes it.
        end
    end
end

-- Replay at most one queued tap, once nothing is in flight.
function PanelZoomIntegration:_flushPendingNav()
    local pending = self._pending_nav
    if not pending then return end
    if self._is_switching or self._is_changing_page then
        Perf:note("queued '%s' tap still not replayable (switching=%s, changing_page=%s)",
            pending, tostring(self._is_switching), tostring(self._is_changing_page))
        return
    end
    self._pending_nav = nil
    if not self._current_imgviewer then
        Perf:note("queued '%s' tap DROPPED: viewer is gone", pending)
        self._pending_nav_count = 0
        self._pending_nav_at = nil
        return
    end
    -- Only one press survives the queue, so N presses during a slow page turn
    -- advance one step. That collapse is what makes presses look ignored.
    local waited = Perf:elapsed(self._pending_nav_at)
    local collapsed = math.max((self._pending_nav_count or 1) - 1, 0)
    logger.info("DynamicPanelZoom: replaying queued " .. pending .. " tap")
    Perf:note("replaying queued '%s' tap after %.0f ms (%d further press(es) collapsed into this one)",
        pending, waited, collapsed)
    self._replaying_nav = true
    if pending == "right" then
        self:handleTapRight()
    else
        self:handleTapLeft()
    end
    self._replaying_nav = false
end

function PanelZoomIntegration:closeViewer()
    Perf:abandon("panel viewer closed")
    self._pending_nav = nil
    self._pending_nav_count = 0
    self._pending_nav_at = nil
    if self._current_imgviewer then
        -- Ensure E-Ink refresh suppression is restored if we were mid-page-change
        if UIManager.currently_scrolling then
            UIManager.currently_scrolling = false
        end
        UIManager:close(self._current_imgviewer)
        self._current_imgviewer = nil
        self:cleanupPreloadedImage()
        -- Free the composite we owned (the viewer never frees it: it keeps
        -- image == _image_bb, so its freeResources leaves ours alone).
        if self._composite_bb then
            self._composite_bb:free()
            self._composite_bb = nil
        end
        -- Restore OCR when panel viewer is closed
        self:restoreOCR()
    end
    -- Always clear in-flight page-change state on exit so re-entering panel
    -- view on a new page can't inherit a stuck _is_changing_page from a
    -- prior session where onPageUpdate didn't fire.
    self._is_changing_page = false
    self._page_change_diff = nil
    self._page_change_started_at = nil
    self._autoskip_count = 0
    -- Cross-page offsets are only valid within a continuous navigation session;
    -- drop them so reopening panel view shows the full current page.
    self._row_offsets = {}
end

-- Preload the next panel in background
function PanelZoomIntegration:preloadNextPanel()
    local t_pre = Perf:mark()
    -- Clean up any existing preloaded image
    self:cleanupPreloadedImage()
    
    local reading_dir = self:getEffectiveReadingDirection()
    local is_rtl = reading_dir == "rtl"
    
    -- In absolute terms, "next" means index+1 (if LTR) or index-1 (if RTL)
    -- Actually, wait: the index IS correctly sorted in importToggleZoomPanels based on reading direction!
    -- Yes, the array is ALWAYS sorted so that index 1 is the START and index N is the END of the page.
    -- So "next panel in logical reading order" is always index + 1!
    local next_panel_index = self.current_panel_index + 1
    
    -- Check if there's a next panel to preload
    if next_panel_index <= #self.current_panels then
        local next_panel = self.current_panels[next_panel_index]
        
        if next_panel and next_panel.composite then
            -- A cross-page composite: resolve (analyzes the next page, off the
            -- critical path here) and render it now so the boundary press is
            -- instant. If it downgrades to a lonely row, fall through to normal.
            self:resolveComposite(next_panel)
            if next_panel.composite then
                local image, custom_position = self:renderCompositeUnit(next_panel)
                if image then
                    self._preloaded_image = image
                    self._preloaded_panel_index = next_panel_index
                    self._preloaded_is_composite = true
                    self._preloaded_custom_position = custom_position
                    Perf:note("preloaded composite unit %d in %.0f ms",
                        next_panel_index, Perf:elapsed(t_pre))
                else
                    Perf:note("preload of composite unit %d FAILED after %.0f ms",
                        next_panel_index, Perf:elapsed(t_pre))
                end
                return
            end
        end

        if next_panel then
            logger.info(string.format("DynamicPanelZoom: Preloading panel %d in background", next_panel_index))

            local page = self:getSafePageNumber()
            local dim = self.ui.document:getNativePageDimensions(page)
            
            if dim then
                -- Calculate and log panel center coordinates for preloaded panel
                local center = self:calculatePanelCenter(next_panel, dim)
                
                -- Use helper function for center-preserving quantization
                local margin = self.standard_margin_percent or 0.0
                local rect = self:panelToRect(next_panel, dim, margin)
                
                -- Render the next panel with document settings (standard margins for preloading)
                local image, rotate, custom_position = self:drawPagePartWithSettings(page, rect, center, next_panel, dim)
                -- Store preloaded image with panel data for proper centering
                if image then
                    self._preloaded_image = image
                    self._preloaded_panel_index = next_panel_index
                    self._preloaded_panel = next_panel  -- Store panel data
                    self._preloaded_dim = dim          -- Store dimensions
                    self._preloaded_custom_position = custom_position  -- Store calculated position
                    logger.info("DynamicPanelZoom: Successfully preloaded next panel with document settings")
                    Perf:note("preloaded panel %d in %.0f ms (this runs on the UI thread, so a press landing inside this window waits for it)",
                        next_panel_index, Perf:elapsed(t_pre))
                else
                    logger.warn("DynamicPanelZoom: Failed to preload next panel")
                    Perf:note("preload of panel %d FAILED after %.0f ms", next_panel_index, Perf:elapsed(t_pre))
                end
            end
        end
    else
        -- Nothing is preloaded past the last unit of a page, so the next forward
        -- press pays for the whole page turn: goto + panel analysis + render.
        Perf:note("NO PRELOAD: panel %d is the last unit on this page, so the next forward press pays for a full page turn",
            self.current_panel_index)
    end
end

-- Display preloaded panel instantly
function PanelZoomIntegration:displayPreloadedPanel()
    if not self._preloaded_image or not self._current_imgviewer then
        logger.warn("DynamicPanelZoom: No preloaded image or viewer available")
        return false
    end
    
    logger.info("DynamicPanelZoom: Displaying preloaded panel instantly")
    local t_show = Perf:mark()

    -- Capture ownership info before updateImage/clearing: a preloaded composite is
    -- a buffer we own and must hand to _setDisplayedComposite so the previously
    -- shown composite (if any) gets freed.
    local shown_image = self._preloaded_image
    local shown_is_composite = self._preloaded_is_composite

    -- Update existing viewer with preloaded image using PanelViewer's method
    self._current_imgviewer:updateImage(self._preloaded_image)
    -- Now the viewer holds shown_image; free the previous composite if this one
    -- replaced it (nil for a normal panel frees any composite we were holding).
    self:_setDisplayedComposite(shown_is_composite and shown_image or nil)

    -- Get screen and image dimensions
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local image_w = self._preloaded_image:getWidth()
    local image_h = self._preloaded_image:getHeight()
    
    -- Use the pre-calculated center-locked position instead of simple centering
    local custom_position = self._preloaded_custom_position or {
        x = math.floor(((screen_w - image_w) / 2) + 0.5),
        y = math.floor(((screen_h - image_h) / 2) + 0.5),
    }
    
    logger.info(string.format("PanelZoom: Using preloaded center-locked position - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self._current_imgviewer:updateCustomPosition(custom_position)
    logger.info(string.format("PanelZoom: Updated custom position for preloaded panel - x:%d, y:%d (image:%dx%d, screen:%dx%d)", 
        custom_position.x, custom_position.y, image_w, image_h, screen_w, screen_h))
    
    self._current_imgviewer:update(self:_panelRefreshMode())
    
    -- Clear preloaded data after use. Do NOT free shown_image: if it was a
    -- composite its ownership just moved to _composite_bb; if it was a normal
    -- panel it is a cache-managed tile.
    self._preloaded_image = nil
    self._preloaded_panel_index = nil
    self._preloaded_is_composite = false
    self._preloaded_panel = nil
    self._preloaded_dim = nil
    self._preloaded_custom_position = nil

    Perf:step("show preloaded panel", t_show, "index %d", self.current_panel_index)

    -- Start preloading the next panel
    UIManager:scheduleIn(0.1, function()
        self:preloadNextPanel()
    end)

    return true
end

-- Custom drawPagePart that applies document settings
function PanelZoomIntegration:drawPagePartWithSettings(pageno, rect, panel_center, panel, dim, scale_override)
    -- 1. Document & Screen Settings
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0
    
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- 2. DEFINE ABSOLUTE LIMIT SAFE ZONE
    local padding = 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)

    -- 3. CALCULATE SCALE (Must fit inside Safe Zone)
    local final_scale = 1.0
    if scale_override then
        final_scale = scale_override
        logger.info(string.format("DynamicPanelZoom: Using override scale %.4f", final_scale))
    else
        local scale_w = safe_w / rect.w
        local scale_h = safe_h / rect.h
        final_scale = math.min(scale_w, scale_h)
    end

    -- Calculate final display dimensions
    local display_w = math.floor(rect.w * final_scale + 0.5)
    local display_h = math.floor(rect.h * final_scale + 0.5)

    -- 4. ORIGINAL CENTERING LOGIC
    -- We calculate the top-left to perfectly center the box on screen
    local pos_x = (screen_w - display_w) / 2
    local pos_y = (screen_h - display_h) / 2

    -- 5. CLAMPING TO ABSOLUTE LIMITS
    -- Forces the panel to stay at least 5px from any edge
    local custom_position = {
        x = math.floor(math.max(padding, math.min(pos_x, screen_w - display_w - padding)) + 0.5),
        y = math.floor(math.max(padding, math.min(pos_y, screen_h - display_h - padding)) + 0.5)
    }

    -- 6. ASPECT RATIO NUDGES (Original offsets)
    if panel and dim then
        local panel_aspect_ratio = (panel.w * dim.w) / (panel.h * dim.h)
        if panel_aspect_ratio >= 0.67 then
            custom_position.x = custom_position.x - 1
        else
            custom_position.y = custom_position.y - 0
        end
    end

    -- 7. RENDER
    -- Create the geometry for MuPDF
    local geom_rect = Geom:new(rect)
    local scaled_rect = geom_rect:copy()
    scaled_rect:transformByScale(final_scale, final_scale)
    rect.scaled_rect = scaled_rect

    local t_render = Perf:mark()
    -- Args: (pageno, rect, zoom, rotation, gamma, saturation, hinting). Current
    -- KOReader put `saturation` in slot 6 (older builds had `hinting` there); pass
    -- neutral saturation 1.0 + hinting true so this works on both -- a bare `true`
    -- in slot 6 crashes new builds (concatenating a boolean saturation).
    local tile = self.ui.document:renderPage(pageno, rect, final_scale, 0, gamma, 1.0, true)
    local image = tile.bb
    Perf:step("  renderPage (MuPDF)", t_render, "%dx%d at scale %.3f, page %d",
        display_w, display_h, final_scale, pageno)

    -- 8. POST-PROCESSING
    if image then
        local t_post = Perf:mark()
        if contrast ~= 1.0 and image.contrast then
            image:contrast(contrast)
        end
        if doc_cfg.invert and image.invert then
            image:invert()
        end
        if contrast ~= 1.0 or doc_cfg.invert then
            Perf:step("  post-process image", t_post, "contrast=%.2f invert=%s",
                contrast, tostring(doc_cfg.invert or false))
        end
        
        logger.info(string.format("DynamicPanelZoom: [Safe Zone %dpx] Rendered %dx%d at (%d,%d)", 
            padding, display_w, display_h, custom_position.x, custom_position.y))
    end

    return image, false, custom_position
end

-- Render one page rect at an explicit scale, returning a settings-applied
-- BlitBuffer. Unlike drawPagePartWithSettings this does no screen-fit/centering:
-- it is a building block for the cross-page composite, which lays out the pieces
-- itself. The returned bb is a document tile (cache-managed) -- never free it.
function PanelZoomIntegration:renderPageRectAtScale(pageno, rect, scale)
    local doc_cfg = self.ui.document.info.config or {}
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    local contrast = doc_cfg.contrast or 1.0

    local geom_rect = Geom:new(rect)
    local scaled_rect = geom_rect:copy()
    scaled_rect:transformByScale(scale, scale)
    rect.scaled_rect = scaled_rect

    -- See drawPagePartWithSettings for the saturation/hinting arg note.
    local tile = self.ui.document:renderPage(pageno, rect, scale, 0, gamma, 1.0, true)
    local image = tile and tile.bb
    if image then
        if contrast ~= 1.0 and image.contrast then image:contrast(contrast) end
        if doc_cfg.invert and image.invert then image:invert() end
    end
    return image
end

-- Page-pixel crop rect for a normalized row, with a small symmetric pad, clamped
-- to the page.
local function rowRectToPagePixels(row, dim)
    local pad = 2
    local r = {
        x = row.x * dim.w - pad,
        y = row.y * dim.h - pad,
        w = row.w * dim.w + pad * 2,
        h = row.h * dim.h + pad * 2,
    }
    r.w = math.min(r.w, dim.w)
    r.h = math.min(r.h, dim.h)
    r.x = math.max(0, math.min(r.x, dim.w - r.w))
    r.y = math.max(0, math.min(r.y, dim.h - r.h))
    return r
end

-- Render a cross-page composite unit: the leftover row of this page stacked over
-- the first row of the next page, scaled together to fill the screen. Returns a
-- freshly allocated BlitBuffer WE own (freed via _setDisplayedComposite /
-- cleanupPreloadedImage) plus its centered screen position. Returns nil if the
-- unit has no resolved parts (caller should fall back to the normal path).
function PanelZoomIntegration:renderCompositeUnit(unit)
    self:resolveComposite(unit)
    local parts = unit.parts
    if not parts or #parts < 2 then return nil end

    local Blitbuffer = require("ffi/blitbuffer")
    local Screen = require("device").screen
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    local padding = 5
    local gap = math.max(2, math.floor(screen_h * 0.01))
    local safe_w = screen_w - padding * 2
    local safe_h = screen_h - padding * 2 - gap

    local r1 = rowRectToPagePixels(parts[1].rect, parts[1].dim)
    local r2 = rowRectToPagePixels(parts[2].rect, parts[2].dim)

    -- One shared scale so both rows share the final width and the stack fits the
    -- screen safe area.
    local max_w = math.max(r1.w, r2.w)
    local sum_h = r1.h + r2.h
    if max_w <= 0 or sum_h <= 0 then return nil end
    local scale = math.min(safe_w / max_w, safe_h / sum_h)

    local t_render = Perf:mark()
    local img1 = self:renderPageRectAtScale(parts[1].page, r1, scale)
    local img2 = self:renderPageRectAtScale(parts[2].page, r2, scale)
    if not img1 or not img2 then return nil end
    Perf:step("render composite parts", t_render, "pages %d+%d at scale %.3f",
        parts[1].page, parts[2].page, scale)

    local w1, h1 = img1:getWidth(), img1:getHeight()
    local w2, h2 = img2:getWidth(), img2:getHeight()
    local total_w = math.max(w1, w2)
    local total_h = h1 + gap + h2

    -- Match the source buffer type so color pages composite correctly; guard the
    -- lookup so an older build without :getType() falls back to the default type
    -- (blitFrom still converts correctly, just less optimally).
    local bbtype = (img1.getType and img1:getType()) or nil
    local canvas = Blitbuffer.new(total_w, total_h, bbtype)
    canvas:fill(Blitbuffer.Color8(255))  -- white, same idiom as PanelViewer:paintTo
    canvas:blitFrom(img1, math.floor((total_w - w1) / 2 + 0.5), 0, 0, 0, w1, h1)
    canvas:blitFrom(img2, math.floor((total_w - w2) / 2 + 0.5), h1 + gap, 0, 0, w2, h2)
    -- img1/img2 are document tiles owned by the render cache; do not free them.

    local custom_position = {
        x = math.floor((screen_w - total_w) / 2 + 0.5),
        y = math.floor((screen_h - total_h) / 2 + 0.5),
    }
    logger.info(string.format(
        "DynamicPanelZoom: composited %dx%d image at (%d,%d)",
        total_w, total_h, custom_position.x, custom_position.y))
    return canvas, custom_position
end

-- Track the composite BlitBuffer currently handed to the viewer so it can be
-- freed when replaced. Call AFTER updateImage/show with the composite now shown
-- (or nil for a normal panel): the previous one is no longer referenced by the
-- viewer, so freeing it here is safe. Normal panels use cache-managed tiles and
-- pass nil, which frees any composite we were holding.
function PanelZoomIntegration:_setDisplayedComposite(bb)
    local prev = self._composite_bb
    self._composite_bb = bb
    if prev and prev ~= bb then
        prev:free()
    end
end

-- Apply KOReader's contrast and gamma settings to image buffer
-- This can be used for preloaded images or manual refreshes
function PanelZoomIntegration:applyDocumentSettings(image)
    if not image then return false end
    
    local doc_cfg = self.ui.document.info.config or {}
    local contrast = doc_cfg.contrast or 1.0
    local gamma = self.ui.view.state.gamma or doc_cfg.gamma or 1.0
    
    -- Contrast
    if image.contrast and contrast ~= 1.0 then
        image:contrast(contrast)
        logger.info(string.format("DynamicPanelZoom: Applied contrast %.2f", contrast))
    end
    
    -- Gamma (if not handled during renderPage)
    if image.gamma and gamma ~= 1.0 then
        image:gamma(gamma)
        logger.info(string.format("DynamicPanelZoom: Applied gamma %.2f", gamma))
    end
    
    -- Invert
    if image.invert and doc_cfg.invert then
        image:invert()
        logger.info("DynamicPanelZoom: Applied image inversion")
    end
    
    return true
end

-- Clean up preloaded image to prevent memory leaks
function PanelZoomIntegration:cleanupPreloadedImage()
    if self._preloaded_image then
        logger.info("DynamicPanelZoom: Cleaning up preloaded image")
        -- Normal preloads are cache-managed document tiles; a preloaded composite
        -- is a buffer we own and must free (it was staged, never displayed, so it
        -- was not transferred to _composite_bb).
        if self._preloaded_is_composite then
            self._preloaded_image:free()
        end
        self._preloaded_image = nil
        self._preloaded_panel_index = nil
        self._preloaded_custom_position = nil
    end
    self._preloaded_is_composite = false
    self._preloaded_panel = nil
    self._preloaded_dim = nil
end

function PanelZoomIntegration:changePage(diff)
    -- DO NOT close the current panel viewer immediately.
    -- Leaving it open keeps the screen covered with the last panel
    -- while KOReader renders the new full page in the background,
    -- preventing the "flash of full page" spoiler.

    -- Resolve the target page up front so the jump below can be absolute, and
    -- so we never start a page change that has nowhere to go.
    local from_page = self:getSafePageNumber()
    local target_page = from_page + diff
    local page_count = self.ui.document.getPageCount and self.ui.document:getPageCount() or nil
    if target_page < 1 or (page_count and target_page > page_count) then
        logger.info(string.format("DynamicPanelZoom: No page %d to turn to (document has %s pages)",
            target_page, tostring(page_count or "?")))
        Perf:event("page turn refused: page %d is outside 1..%s", target_page, tostring(page_count or "?"))
        Perf:finish("no page to turn to")
        return
    end

    -- Records whether the underlying view had room to pan, which is what used
    -- to make relative page turns swallow the first press.
    if self.ui.view then
        local va, pa = self.ui.view.visible_area, self.ui.view.page_area
        Perf:event("view state: zoom_mode=%s page_scroll=%s visible=%s page_area=%s",
            tostring(self.ui.zooming and self.ui.zooming.zoom_mode),
            tostring(self.ui.view.page_scroll),
            va and string.format("%dx%d", va.w, va.h) or "?",
            pa and string.format("%dx%d", pa.w, pa.h) or "?")
    end

    -- Clear preloaded cache immediately to prevent ghost images
    self:cleanupPreloadedImage()

    -- Save current state for the event-driven flow
    self._is_changing_page = true
    self._page_change_diff = diff
    -- Everything from here until _onPageChangeComplete() is a window in which
    -- presses cannot be acted on; _notePressQueued() reports its length.
    self._page_change_started_at = Perf:mark()
    Perf:event("page change START (diff=%d) -- presses are queued from here on", diff)

    -- FLASH PREVENTION: Suppress E-Ink screen refreshes while KOReader
    -- renders the new page underneath our PanelViewer.
    -- `currently_scrolling = true` forces all refresh modes to "fast" (no flash).
    UIManager.currently_scrolling = true

    -- Safety net: if onPageUpdate never fires (legacy Kindle builds, missed
    -- events, etc.), _is_changing_page would stay true forever and silently
    -- drop every subsequent handleTapRight/Left/Key navigation, making the
    -- viewer look softlocked. Force-reset both the E-Ink refresh suppression
    -- and the page-change flag after 1s so the worst case is a 1s delay, not
    -- a permanent dead viewer.
    UIManager:scheduleIn(1.0, function()
        if UIManager.currently_scrolling then
            logger.warn("DynamicPanelZoom: Safety net restored currently_scrolling to false")
            UIManager.currently_scrolling = false
        end
        if self._is_changing_page then
            logger.warn("DynamicPanelZoom: Safety net forced _is_changing_page to false (onPageUpdate likely never fired)")
            Perf:step("SAFETY NET (no PageUpdate)", self._page_change_started_at)
            Perf:finish("page change never completed -- 1s lost to the safety net")
            self._is_changing_page = false
            self._page_change_diff = nil
            self._page_change_started_at = nil
            self:_flushPendingNav()
        end
    end)

    -- Trigger page navigation.
    --
    -- This MUST be an absolute jump. ReaderPaging:onGotoViewRel() is pan-aware:
    -- in any zoom mode that is not fit-page (fit-width in landscape, say, where
    -- the page is taller than the screen), it first pans the underlying page by
    -- one screenful and only turns the page once panning runs out. Panning emits
    -- no PageUpdate, so from here the turn looks like it simply never happened,
    -- _is_changing_page stays set until the 1s safety net, and the user has to
    -- press again -- deterministically twice per page boundary.
    --
    -- onGotoPage() ignores pan state and lands on the page we asked for, and it
    -- is synchronous: _gotoPage() emits PageUpdate before returning, so our
    -- onPageUpdate handler picks it up and calls _onPageChangeComplete().
    if self.ui.paging and self.ui.paging.onGotoPage then
        local t_goto = Perf:mark()
        self.ui.paging:onGotoPage(target_page)
        local landed = self:getSafePageNumber()
        Perf:step("onGotoPage", t_goto, "page %d -> %d (asked for %d)", from_page, landed, target_page)
        logger.info(string.format("DynamicPanelZoom: Used ui.paging.onGotoPage(%d), landed on %d",
            target_page, landed))
        if landed ~= target_page then
            logger.warn(string.format("DynamicPanelZoom: onGotoPage(%d) landed on %d instead",
                target_page, landed))
        end
    elseif self.ui.paging and self.ui.paging.onGotoViewRel then
        -- Older builds without onGotoPage: relative turn, pan-eating and all.
        local t_goto = Perf:mark()
        self.ui.paging:onGotoViewRel(diff)
        Perf:step("onGotoViewRel (fallback)", t_goto, "diff=%d, page %d -> %d",
            diff, from_page, self:getSafePageNumber())
        logger.info(string.format("DynamicPanelZoom: Used ui.paging.onGotoViewRel(%d)", diff))
    else
        -- Fallback to key event — this path does NOT guarantee a PageUpdate event,
        -- so we handle it directly with nextTick as a safety measure.
        local key = diff > 0 and "Right" or "Left"
        local t_key = Perf:mark()
        UIManager:sendEvent({ key = key, modifiers = {} })
        Perf:step("key event fallback", t_key, "key=%s", key)
        logger.info(string.format("DynamicPanelZoom: Used %s key event as fallback", key))
        -- Since key events may not trigger onPageUpdate synchronously,
        -- schedule the completion handler ourselves.
        self:_onPageChangeComplete(nil)
    end
end

-- Handle page change completion. Called by onPageUpdate (event-driven) or
-- directly from changePage() fallback path. Uses nextTick to ensure all
-- other PageUpdate handlers (ReaderView, ReaderZooming, etc.) have finished
-- processing before we load our panel.
function PanelZoomIntegration:_onPageChangeComplete(new_page_no)
    local t_tick = Perf:mark()
    UIManager:nextTick(function()
        Perf:step("nextTick wait", t_tick, "other PageUpdate handlers ran here")
        -- Restore normal refresh behavior now that we're ready to show our panel
        UIManager.currently_scrolling = false
        -- Only suppress the flash when the user asked for no page-turn flash;
        -- otherwise let our own counter decide (see _panelRefreshMode).
        if not self.flash_on_page_turn then
            UIManager:avoidFlashOnNextRepaint()
        end

        local new_page = new_page_no or self:getSafePageNumber()
        local diff = self._page_change_diff or 1
        logger.info(string.format("DynamicPanelZoom: Page change complete - page %d (diff: %d)", new_page, diff))
        self.last_page_seen = new_page

        local t_panels = Perf:mark()
        self:importToggleZoomPanels()
        Perf:step("panels for new page", t_panels, "%d unit(s)", #self.current_panels)

        -- A page whose rows were entirely pulled into the previous page's
        -- composite has no units of its own; skip past it in the same direction
        -- rather than showing "no panels". Bounded so a run of empties can't loop.
        if #self.current_panels == 0 and (self._row_offsets[new_page] or 0) > 0
                and (self._autoskip_count or 0) < 3 then
            self._autoskip_count = (self._autoskip_count or 0) + 1
            logger.info(string.format(
                "DynamicPanelZoom: page %d fully consumed by previous composite, skipping (%d)",
                new_page, self._autoskip_count))
            Perf:event("page %d fully consumed by composite -> auto-skip %d", new_page, self._autoskip_count)
            self._is_changing_page = false
            self._page_change_diff = nil
            self._page_change_started_at = nil
            self:changePage(diff)
            return
        end
        self._autoskip_count = 0

        if #self.current_panels > 0 then
            -- Moving Forward (diff > 0): Start at first panel of new page.
            -- Moving Backward (diff < 0): Start at last panel of previous page.
            self.current_panel_index = (diff > 0) and 1 or #self.current_panels
            if self.flash_on_page_turn then self:_forceFullRefreshNext() end
            local t_display = Perf:mark()
            self:displayCurrentPanel()
            Perf:step("displayCurrentPanel", t_display)
        else
            UIManager:show(InfoMessage:new{ text = _("No panels on this page"), timeout = 1 })
            self:closeViewer()
        end

        self._is_changing_page = false
        self._page_change_diff = nil
        self._page_change_started_at = nil
        Perf:finish("landed on page %d, panel %d/%d", new_page,
            self.current_panel_index, #self.current_panels)
        UIManager:nextTick(function() self:_flushPendingNav() end)
    end)
end

function PanelZoomIntegration:getSafePageNumber()
    -- Try multiple methods to get the current page number
    local page = nil
    
    -- Method 1: Try ui.paging.getPage()
    if self.ui.paging and self.ui.paging.getPage then 
        page = self.ui.paging:getPage()
        logger.info(string.format("PanelZoom: Method 1 - ui.paging.getPage() -> %d", page))
    end
    
    -- Method 2: Try ui.paging.cur_page
    if not page and self.ui.paging and self.ui.paging.cur_page then 
        page = self.ui.paging.cur_page
        logger.info(string.format("PanelZoom: Method 2 - ui.paging.cur_page -> %d", page))
    end
    
    -- Method 3: Try ui.document.current_page
    if not page and self.ui.document and self.ui.document.current_page then 
        page = self.ui.document.current_page
        logger.info(string.format("PanelZoom: Method 3 - ui.document.current_page -> %d", page))
    end
    
    -- Method 4: Try ui.view.state.page
    if not page and self.ui.view and self.ui.view.state and self.ui.view.state.page then 
        page = self.ui.view.state.page
        logger.info(string.format("PanelZoom: Method 4 - ui.view.state.page -> %d", page))
    end
    
    -- Method 5: Try getting from the highlighting system
    if not page and self.ui.highlight and self.ui.highlight.page then 
        page = self.ui.highlight.page
        logger.info(string.format("PanelZoom: Method 5 - ui.highlight.page -> %d", page))
    end
    
    -- Fallback
    if not page then 
        page = 1
        logger.info("PanelZoom: Using fallback page number 1")
    end
    
    return page
end

function PanelZoomIntegration:onIntegratedPanelZoom(arg, ges)
    -- Ensure we have the gesture object
    local actual_ges = (type(arg) == "table" and arg.pos) and arg or ges
    
    -- If JSON is not available, fall back to built-in Panel Zoom
    if not self._json_available then
        logger.info("DynamicPanelZoom: JSON not available, using built-in Panel Zoom")
        if self._original_panel_zoom_handler then
            return self._original_panel_zoom_handler(self.ui.highlight, arg, ges)
        end
        return false
    end
    
    local current_page = self:getSafePageNumber()
    Perf:begin("enter-panel-mode", "page %d", current_page)
    logger.info(string.format("DynamicPanelZoom: onIntegratedPanelZoom called - current_page: %d, last_page_seen: %d, panels_count: %d",
        current_page, self.last_page_seen or -1, #self.current_panels))
    
    -- Force import if page changed or panels empty
    if current_page ~= self.last_page_seen or #self.current_panels == 0 then
        logger.info(string.format("DynamicPanelZoom: Page changed or no panels - importing for page %d", current_page))
        self.last_page_seen = current_page
        local t_panels = Perf:mark()
        self:importToggleZoomPanels()
        Perf:step("panels for page", t_panels, "%d unit(s)", #self.current_panels)
    else
        logger.info(string.format("DynamicPanelZoom: Using cached panels for page %d", current_page))
    end

    if #self.current_panels > 0 then
        -- Initial launch of Panel Viewer on a page
        -- In LTR, start at index 1 (top-left). In RTL, start at index 1 (top-right).
        self.current_panel_index = 1
        local t_display = Perf:mark()
        local shown = self:displayCurrentPanel()
        Perf:step("displayCurrentPanel", t_display)
        Perf:finish("panel 1/%d", #self.current_panels)
        return shown
    end

    logger.warn("DynamicPanelZoom: No panels found for this page in JSON.")
    Perf:finish("no panels on this page")
    return false
end

function PanelZoomIntegration:importToggleZoomPanels()
    local doc_path = self.ui.document.file
    if not doc_path then return end
    
    local page_idx = self:getSafePageNumber()
    local reading_dir = self:getEffectiveReadingDirection()

    -- The cache key includes reading_dir; getRawPanelsForPage owns the analysis
    -- and caching (also used to reach into the next page for composites). We only
    -- add the hit/miss tracing here, cheaply, by checking the cache first.
    local had_cache = self._panel_cache[doc_path]
        and self._panel_cache[doc_path][reading_dir]
        and self._panel_cache[doc_path][reading_dir][page_idx] ~= nil
    local t_analyze = Perf:mark()
    local raw = self:getRawPanelsForPage(page_idx)
    if had_cache then
        logger.info(string.format("DynamicPanelZoom: Using cached %s panels for page %d", reading_dir, page_idx))
        Perf:event("panel analysis served from cache (page %d, %d raw panels)", page_idx, #raw)
    else
        logger.info(string.format("DynamicPanelZoom: Analyzing page %d for %s panels dynamically", page_idx, reading_dir))
        Perf:step("analyze page (CACHE MISS)", t_analyze, "page %d, %d raw panels, %s",
            page_idx, #raw,
            self.experimental_panel_sorting_enabled and "experimental sorter" or "default sorter")
    end

    local t_units = Perf:mark()
    self.current_panels = self:buildViewUnits(raw, page_idx)
    Perf:step("buildViewUnits", t_units, "%d unit(s), row_mode=%s",
        #self.current_panels, tostring(self.row_mode))

    if #self.current_panels > 0 then
        logger.info(string.format("DynamicPanelZoom: SUCCESS! Detected %d panels for page %d (%s)", #self.current_panels, page_idx, reading_dir))
    else
        logger.warn(string.format("DynamicPanelZoom: No panels detected on page %d", page_idx))
    end
end

function PanelZoomIntegration:analyzePageForPanels(pageno)
    local ffi = require("ffi")
    local leptonica = ffi.loadlib("leptonica", "6")
    
    if not self.ui.document or not self.ui.document._document then return {} end
    
    -- Re-use or instantiate KOPTContext
    local KOPTContext = require("ffi/koptcontext")
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    
    if not page_size then return {} end
    
    -- Limit the dimensions to avoid OOM or slow processing
    local target_w = page_size.w
    local target_h = page_size.h
    
    local bbox = {
        x0 = 0, y0 = 0,
        x1 = target_w,
        y1 = target_h,
    }
    
    -- We can get the koptinterface from pdfdocument/cbzdocument if needed,
    -- or manually via KoptInterface:createContext
    local Document = require("document/document")
    local koptinterface
    if self.ui.document.koptinterface then
        koptinterface = self.ui.document.koptinterface
    end
    
    local kc
    if koptinterface and koptinterface.createContext then
        kc = koptinterface:createContext(self.ui.document, pageno, bbox)
    else
        -- Fallback: manual creation
        kc = KOPTContext.new()
        kc:setZoom(1.0)
        kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    end
    
    local t_open = Perf:mark()
    local page = self.ui.document._document:openPage(pageno)
    if not page then
        if kc.free then kc:free() end
        return {}
    end
    Perf:step("  openPage", t_open, "page %d", pageno)

    -- Assigned by the connected-component pass below; declared here so the
    -- spans can be closed after the block that opens them.
    local t_lepto, t_boxes, box_count

    local t_pix = Perf:mark()
    page:getPagePix(kc, self.ui.document.render_mode)
    Perf:step("  getPagePix", t_pix, "full-page bitmap %dx%d", target_w, target_h)
    
    local panels = {}
    
    if kc.src.data then
        local KOPTContextClass = require("ffi/koptcontext")
        local k2pdfopt = KOPTContextClass.k2pdfopt
        
        -- Helper destructors for FFI to avoid memory leaks
        local function _gc_ptr(p, destructor)
            return p and ffi.gc(p, destructor)
        end
        local function pixDestroy(pix)
            leptonica.pixDestroy(ffi.new('PIX *[1]', pix))
            ffi.gc(pix, nil)
        end
        local function boxDestroy(box)
            leptonica.boxDestroy(ffi.new('BOX *[1]', box))
            ffi.gc(box, nil)
        end
        local function boxaDestroy(boxa)
            leptonica.boxaDestroy(ffi.new('BOXA *[1]', boxa))
            ffi.gc(boxa, nil)
        end

        t_lepto = Perf:mark()
        local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height), pixDestroy)
        
        local pixg
        if leptonica.pixGetDepth(pixs) == 32 then
            pixg = leptonica.pixConvertRGBToGrayFast(pixs)
        else
            pixg = leptonica.pixClone(pixs)
        end
        pixg = _gc_ptr(pixg, pixDestroy)
        
        local pix_inverted = _gc_ptr(leptonica.pixInvert(nil, pixg), pixDestroy)
        local pix_thresholded = _gc_ptr(leptonica.pixThresholdToBinary(pix_inverted, 50), pixDestroy)
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        
        local bb = _gc_ptr(leptonica.pixConnCompBB(pix_thresholded, 8), boxaDestroy)
        Perf:step("  leptonica gray+CC", t_lepto)
        
        local img_w = leptonica.pixGetWidth(pixs)
        local img_h = leptonica.pixGetHeight(pixs)
        
        local function boxGetGeometry(box)
            local geo = ffi.new('l_int32[4]')
            leptonica.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
            return tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])
        end

        local count = leptonica.boxaGetCount(bb)
        box_count = tonumber(count)
        t_boxes = Perf:mark()
        for index = 0, count - 1 do
            local box = _gc_ptr(leptonica.boxaGetBox(bb, index, leptonica.L_CLONE), boxDestroy)
            
            local pix_tmp = _gc_ptr(leptonica.pixClipRectangle(pixs, box, nil), pixDestroy)
            local w = leptonica.pixGetWidth(pix_tmp)
            local h = leptonica.pixGetHeight(pix_tmp)
            
            if w >= img_w / 8 and h >= img_h / 8 then
                local box_x, box_y, box_w, box_h = boxGetGeometry(box)
                
                table.insert(panels, {
                    x = box_x / target_w,
                    y = box_y / target_h,
                    w = box_w / target_w,
                    h = box_h / target_h,
                })
            end
            -- Note: Memory is handled automatically by _gc_ptr!
        end
    end
    
    if t_boxes then
        Perf:step("  component loop", t_boxes, "%d raw components", box_count or -1)
    end
    page:close()
    if kc.free then kc:free() end
    
    -- Sort panels based on reading direction (Manga TR->BL)
    local effective_dir = self:getEffectiveReadingDirection()
    table.sort(panels, function(a, b)
        -- We want to sort primarily top-to-bottom, and secondarily according to direction
        -- If their y ranges overlap significantly, they are on the same "row"
        local a_center_y = a.y + (a.h / 2)
        local b_center_y = b.y + (b.h / 2)
        
        -- Rough same-row threshold ~10% of page height
        if math.abs(a_center_y - b_center_y) < 0.1 then
            if effective_dir == "rtl" then
                return a.x > b.x -- Right to Left
            else
                return a.x < b.x -- Left to Right
            end
        end
        
        return a_center_y < b_center_y -- Top to bottom
    end)
    
    return panels
end

function PanelZoomIntegration:analyzePageForPanelsExperimental(pageno)
    local ffi = require("ffi")
    local leptonica = ffi.loadlib("leptonica", "6")
    
    if not self.ui.document or not self.ui.document._document then return {} end
    
    local KOPTContext = require("ffi/koptcontext")
    local page_size = self.ui.document:getNativePageDimensions(pageno)
    
    if not page_size then return {} end
    
    local target_w = page_size.w
    local target_h = page_size.h
    
    local bbox = {
        x0 = 0, y0 = 0,
        x1 = target_w,
        y1 = target_h,
    }
    
    local Document = require("document/document")
    local koptinterface
    if self.ui.document.koptinterface then
        koptinterface = self.ui.document.koptinterface
    end
    
    local kc
    if koptinterface and koptinterface.createContext then
        kc = koptinterface:createContext(self.ui.document, pageno, bbox)
    else
        kc = KOPTContext.new()
        kc:setZoom(1.0)
        kc:setBBox(bbox.x0, bbox.y0, bbox.x1, bbox.y1)
    end
    
    local t_open = Perf:mark()
    local page = self.ui.document._document:openPage(pageno)
    if not page then
        if kc.free then kc:free() end
        return {}
    end
    Perf:step("  openPage", t_open, "page %d", pageno)

    -- Assigned by the connected-component pass below; declared here so the
    -- spans can be closed after the block that opens them.
    local t_lepto, t_boxes, box_count

    local t_pix = Perf:mark()
    page:getPagePix(kc, self.ui.document.render_mode)
    Perf:step("  getPagePix", t_pix, "full-page bitmap %dx%d", target_w, target_h)
    
    local initial_boxes = {}
    
    if kc.src.data then
        local KOPTContextClass = require("ffi/koptcontext")
        local k2pdfopt = KOPTContextClass.k2pdfopt
        
        local function _gc_ptr(p, destructor)
            return p and ffi.gc(p, destructor)
        end
        local function pixDestroy(pix)
            leptonica.pixDestroy(ffi.new('PIX *[1]', pix))
            ffi.gc(pix, nil)
        end
        local function boxDestroy(box)
            leptonica.boxDestroy(ffi.new('BOX *[1]', box))
            ffi.gc(box, nil)
        end
        local function boxaDestroy(boxa)
            leptonica.boxaDestroy(ffi.new('BOXA *[1]', boxa))
            ffi.gc(boxa, nil)
        end

        t_lepto = Perf:mark()
        local pixs = _gc_ptr(k2pdfopt.bitmap2pix(kc.src, 0, 0, kc.src.width, kc.src.height), pixDestroy)
        
        local pixg
        if leptonica.pixGetDepth(pixs) == 32 then
            pixg = leptonica.pixConvertRGBToGrayFast(pixs)
        else
            pixg = leptonica.pixClone(pixs)
        end
        pixg = _gc_ptr(pixg, pixDestroy)
        
        local pix_inverted = _gc_ptr(leptonica.pixInvert(nil, pixg), pixDestroy)
        local pix_thresholded = _gc_ptr(leptonica.pixThresholdToBinary(pix_inverted, 50), pixDestroy)
        leptonica.pixInvert(pix_thresholded, pix_thresholded)
        
        local bb = _gc_ptr(leptonica.pixConnCompBB(pix_thresholded, 8), boxaDestroy)
        Perf:step("  leptonica gray+CC", t_lepto)
        
        local img_w = leptonica.pixGetWidth(pixs)
        local img_h = leptonica.pixGetHeight(pixs)
        
        local function boxGetGeometry(box)
            local geo = ffi.new('l_int32[4]')
            leptonica.boxGetGeometry(box, geo, geo + 1, geo + 2, geo + 3)
            return tonumber(geo[0]), tonumber(geo[1]), tonumber(geo[2]), tonumber(geo[3])
        end

        local count = leptonica.boxaGetCount(bb)
        box_count = tonumber(count)
        t_boxes = Perf:mark()
        for index = 0, count - 1 do
            local box = _gc_ptr(leptonica.boxaGetBox(bb, index, leptonica.L_CLONE), boxDestroy)
            
            -- We don't filter during extraction, we just get all boxes
            local box_x, box_y, box_w, box_h = boxGetGeometry(box)
            table.insert(initial_boxes, {
                x = box_x / target_w,
                y = box_y / target_h,
                w = box_w / target_w,
                h = box_h / target_h,
            })
        end
    end
    
    if t_boxes then
        Perf:step("  component loop", t_boxes, "%d raw components", box_count or -1)
    end
    page:close()
    if kc.free then kc:free() end

    logger.info(string.format("DynamicPanelZoom (Experimental): Extracted %d raw components from Leptonica", #initial_boxes))

    -- 3.1 Minimum area filter
    local filtered_boxes = {}
    local min_area_threshold = 0.02 -- 2% of page area
    for _, box in ipairs(initial_boxes) do
        local area = box.w * box.h
        -- Also check minimum w/h proportions to avoid extremely thin lines being accepted
        if area >= min_area_threshold and box.w > 0.05 and box.h > 0.05 then
            table.insert(filtered_boxes, box)
        end
    end

    -- 3.2 Nesting check (discard boxes completely contained in others)
    local final_boxes = {}
    for i, box1 in ipairs(filtered_boxes) do
        local is_nested = false
        for j, box2 in ipairs(filtered_boxes) do
            if i ~= j then
                -- Add a small margin of error (0.01) for the nesting check
                if box1.x >= box2.x - 0.01 and box1.y >= box2.y - 0.01 and 
                   (box1.x + box1.w) <= (box2.x + box2.w) + 0.01 and 
                   (box1.y + box1.h) <= (box2.y + box2.h) + 0.01 then
                    is_nested = true
                    break
                end
            end
        end
        if not is_nested then
            table.insert(final_boxes, box1)
        end
    end

    logger.info(string.format("DynamicPanelZoom (Experimental): %d components remaining after filtering", #final_boxes))

    -- 4.1 Sort vertically by top `y` coordinate
    table.sort(final_boxes, function(a, b)
        return a.y < b.y
    end)

    -- 4.2 Group into rows by intersection
    local rows = {}
    local current_row = {}
    local current_row_min_y = nil
    local current_row_max_y = nil

    for _, box in ipairs(final_boxes) do
        if #current_row == 0 then
            table.insert(current_row, box)
            current_row_min_y = box.y
            current_row_max_y = box.y + box.h
        else
            -- Check intersection with current row bounds
            local box_max_y = box.y + box.h
            -- A box intersects the row if its top is before row's bottom, and its bottom is after row's top
            -- Adding a small margin
            local margin = 0.05
            if box.y < current_row_max_y - margin and box_max_y > current_row_min_y + margin then
                -- Belongs to current row
                table.insert(current_row, box)
                -- Update row bounds
                current_row_min_y = math.min(current_row_min_y, box.y)
                current_row_max_y = math.max(current_row_max_y, box_max_y)
            else
                -- Start a new row
                table.insert(rows, current_row)
                current_row = {box}
                current_row_min_y = box.y
                current_row_max_y = box.y + box.h
            end
        end
    end
    if #current_row > 0 then
        table.insert(rows, current_row)
    end

    -- 4.3 Sort each row horizontally and 4.4 Concatenate
    local effective_dir = self:getEffectiveReadingDirection()
    local final_panels = {}
    
    for row_idx, row in ipairs(rows) do
        table.sort(row, function(a, b)
            if effective_dir == "rtl" then
                return a.x > b.x
            else
                return a.x < b.x
            end
        end)
        
        for _, box in ipairs(row) do
            table.insert(final_panels, box)
        end
    end

    -- 5.1 Debug log the final ordered panel sequence
    logger.info(string.format("DynamicPanelZoom (Experimental): Final sequence (%d panels, %d rows) for %s reading direction:", #final_panels, #rows, effective_dir))
    for i, p in ipairs(final_panels) do
        logger.info(string.format("  Panel %d: x=%.3f, y=%.3f, w=%.3f, h=%.3f", i, p.x, p.y, p.w, p.h))
    end

    return final_panels
end

function PanelZoomIntegration:calculatePanelCenter(panel, dim)
    -- Calculate absolute center coordinates from panel JSON data
    -- Center_x = x + w/2, Center_y = y + h/2
    local center_x = panel.x + (panel.w / 2)
    local center_y = panel.y + (panel.h / 2)
    
    -- Convert to absolute pixel coordinates
    local abs_center_x = math.floor(center_x * dim.w + 0.5)
    local abs_center_y = math.floor(center_y * dim.h + 0.5)
    
    logger.info(string.format("PanelZoom: Panel center - normalized:(%.3f, %.3f), absolute:(%d, %d)", 
        center_x, center_y, abs_center_x, abs_center_y))
    
    return {
        x = center_x,
        y = center_y,
        abs_x = abs_center_x,
        abs_y = abs_center_y
    }
end

function PanelZoomIntegration:panelToRect(panel, dim, apply_margin_percent)
    -- Step 1: Compute panel center (NO padding involved) - semantic center only
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h
    
    -- Step 2: Build a padded render rect (crop source)
    -- panel rect in page pixels
    local px = panel.x * dim.w
    local py = panel.y * dim.h
    local pw = panel.w * dim.w
    local ph = panel.h * dim.h
    
    local left_extension = 0
    local right_extension = 0
    local top_extension = 0
    local bottom_extension = 0

    if apply_margin_percent and apply_margin_percent > 0 then
        -- Zoom mode (or standard mode with custom margins): Apply constant absolute margin based on page size
        local base_dimension = math.max(dim.w, dim.h)
        local constant_margin = math.floor(base_dimension * apply_margin_percent + 0.5)
        
        left_extension = constant_margin
        right_extension = constant_margin
        top_extension = constant_margin
        bottom_extension = constant_margin
        logger.info(string.format("PanelZoom: Applying constant %.0fpx expanded margins", constant_margin))
    else
        -- Standard Panel Mode: Use default tight constraints
        local panel_aspect_ratio = pw / ph
        
        left_extension = 2   -- Less extension on left side
        right_extension = 2 -- 4px + 5px more extension on right
        top_extension = 0.5
        bottom_extension = 2.5
    end
    
    local render_rect = {
        x = px - left_extension,
        y = py - top_extension,
        w = pw + left_extension + right_extension,
        h = ph + top_extension + bottom_extension,
    }
    
    -- Clamp to page bounds
    render_rect.w = math.min(render_rect.w, dim.w)
    render_rect.h = math.min(render_rect.h, dim.h)
    render_rect.x = math.max(0, math.min(render_rect.x, dim.w - render_rect.w))
    render_rect.y = math.max(0, math.min(render_rect.y, dim.h - render_rect.h))

    -- Step 3: Smart Fill (Aspect Ratio Expansion)
    if self.show_adjacent_panels then
        local screen_width = Screen:getWidth()
        local screen_height = Screen:getHeight()
        -- Handle landscape mode if orientation changed
        if self.view and self.view.mode == "landscape" then
            screen_width, screen_height = screen_height, screen_width
        end

        local screen_ratio = screen_width / screen_height
        local rect_ratio = render_rect.w / render_rect.h

        if rect_ratio > screen_ratio then
            -- Panel is wider than screen: Need to expand vertically (height)
            local target_new_h = render_rect.w / screen_ratio
            local total_expansion_needed = target_new_h - render_rect.h
            local expansion_per_side = total_expansion_needed / 2
            
            -- V4: Apply expansion symmetrically WITHOUT clamping to document bounds
            -- This allows render_rect.y to be negative and render_rect.h to exceed dim.h
            render_rect.y = render_rect.y - expansion_per_side
            render_rect.h = render_rect.h + (expansion_per_side * 2)
            
        elseif rect_ratio < screen_ratio then
            -- Panel is taller than screen: Need to expand horizontally (width)
            local target_new_w = render_rect.h * screen_ratio
            local total_expansion_needed = target_new_w - render_rect.w
            local expansion_per_side = total_expansion_needed / 2
            
            -- V4: Apply expansion symmetrically WITHOUT clamping to document bounds
            -- This allows render_rect.x to be negative and render_rect.w to exceed dim.w
            render_rect.x = render_rect.x - expansion_per_side
            render_rect.w = render_rect.w + (expansion_per_side * 2)
        end
    end
    
    logger.info(string.format("PanelZoom: Panel center:(%.1f,%.1f) render_rect:(%d,%d,%dx%d)", 
        panel_cx, panel_cy, render_rect.x, render_rect.y, render_rect.w, render_rect.h))
    
    -- Return render rect and panel center for later calculations
    return {
        x = render_rect.x,
        y = render_rect.y,
        w = render_rect.w,
        h = render_rect.h,
        panel_cx = panel_cx,  -- Semantic center (no padding)
        panel_cy = panel_cy   -- Semantic center (no padding)
    }
end


function PanelZoomIntegration:switchToZoomMode()
    logger.info("DynamicPanelZoom: Switching to Free Zoom Mode")
    
    local panel = self.current_panels[self.current_panel_index]
    if not panel then return false end

    local page = self:getSafePageNumber()
    local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
    if not dim then return false end

    -- 1. Get expanded rect (margin for reading text that spills out)
    local margin = self.zoom_margin_percent or 0.05
    local expanded_rect = self:panelToRect(panel, dim, margin)
    local center = self:calculatePanelCenter(panel, dim)
    
    -- 2. DYNAMIC SCALING (To prevent Segmentation Fault)
    -- We cannot render arbitrary large images on E-Ink memory limits.
    -- We calculate the scale so the image buffer NEVER exceeds screen size + a small buffer
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    
    -- Safe memory rendering constraints
    -- E-ink displays can usually handle a buffer 2.5x to 3x their resolution
    -- before hitting SegFaults, but 1.5x is too blurry for comics text.
    -- We raise this to 2.5x to get crisp text while staying safely below the crash threshold.
    local max_buffer_w = screen_w * 2.5
    local max_buffer_h = screen_h * 2.5
    
    -- Find a safe base scale for the MuPDF render phase
    local scale_w = max_buffer_w / expanded_rect.w
    local scale_h = max_buffer_h / expanded_rect.h
    local safe_scale = math.min(scale_w, scale_h, 3.5) -- Raised the hard render scale cap to 3.5x
    
    logger.info(string.format("DynamicPanelZoom: Using safe memory render scale %.4f", safe_scale))

    -- 3. Generate safe expanded image
    local expanded_image, _, _ = self:drawPagePartWithSettings(page, expanded_rect, center, panel, dim, safe_scale)
    if not expanded_image then return false end

    -- Create native ImageViewer using safe dynamic loading
    local ok, ImageViewer = pcall(require, "ui/widget/imageviewer")
    if not ok or type(ImageViewer) ~= "table" then
        logger.warn("DynamicPanelZoom: Failed to load imageviewer widget")
        return false
    end
    
    -- 4. APPLY SOFTWARE ZOOM OVER THE SAFE RENDER
    -- To prevent any visual "jump" when switching to 1.0x, we need to match the exact visual scale 
    -- the user was just looking at in the PanelViewer.
    -- First, calculate what the scale was in the normal PanelViewer:
    local standard_margin = self.standard_margin_percent or 0.0
    local normal_rect = self:panelToRect(panel, dim, standard_margin) -- Rect with standard panel margins
    local padding = 5
    local safe_w = screen_w - (padding * 2)
    local safe_h = screen_h - (padding * 2)
    local normal_scale = math.min(safe_w / normal_rect.w, safe_h / normal_rect.h)
    
    -- The absolute scale we want to achieve on the physical screen (1 pixel image = 1 pixel screen at 1.0x)
    local target_absolute_scale = normal_scale / safe_scale
    
    -- IMPORTANT: ImageViewer doesn't treat scale_factor 1.0 as 1:1 pixels.
    -- It treats 1.0 as "Fit to screen" for the given image within its UI context.
    -- When buttons_visible = true, ImageViewer reserves space at the bottom (usually ~10-12% of screen height).
    local image_w = expanded_image:getWidth()
    local image_h = expanded_image:getHeight()
    
    -- Estimate ImageViewer's actual usable viewport (it reserves bottom space for buttons)
    local Size = require("ui/size")
    local button_bar_height = Size.bottom_menu_height or math.floor(screen_h * 0.1)
    local usable_h = screen_h - button_bar_height
    
    local fit_to_screen_scale = math.min(screen_w / image_w, usable_h / image_h)
    
    -- The software scale factor to pass to ImageViewer to achieve our target absolute scale
    -- Fix: ImageViewer uses explicit scale_factor as absolute scale on the image's native resolution, 
    -- not as a multiplier over fit_to_screen. Therefore, we pass target_absolute_scale directly.
    local base_visual_scale = target_absolute_scale
    
    -- Apply the user's zoom preference on top of that base scale
    local bump_factor = self.zoom_initial_scale or 1.2
    local initial_scale_factor = base_visual_scale * bump_factor
    
    logger.info(string.format("DynamicPanelZoom: ImageViewer usable height approx %d (screen %d)", usable_h, screen_h))
    logger.info(string.format("DynamicPanelZoom: ImageViewer Fit-to-screen scale is %.4f", fit_to_screen_scale))
    logger.info(string.format("DynamicPanelZoom: Required Absolute scale is %.4f", target_absolute_scale))
    logger.info(string.format("DynamicPanelZoom: Setting ImageViewer software scale factor to %.4f (bump: %.1fx)", initial_scale_factor, bump_factor))

    local image_viewer = ImageViewer:new{
        image = expanded_image,
        image_disposable = false, -- Disabled forced deletion to prevent garbage collection races/color noise
        fullscreen = true,
        with_title_bar = false,
        buttons_visible = true, -- Restored native UI buttons and minimap
        scale_factor = initial_scale_factor,
        
        -- Calculate the exact semantic center ratio of the panel inside our cropped expanded image
        -- This ensures the ImageViewer starts positioned right over the panel, compensating for asymmetrical margins near page edges.
        _center_x_ratio = (center.abs_x - expanded_rect.x) / expanded_rect.w,
        _center_y_ratio = (center.abs_y - expanded_rect.y) / expanded_rect.h,
    }

    -- We just push the image_viewer on top of the UI stack. 
    -- The PanelViewer stays underneath. When image_viewer is closed, PanelViewer is instantly revealed without flashing the background page.
    UIManager:show(image_viewer)
    return true
end

function PanelZoomIntegration:displayCurrentPanel()
    logger.info("DynamicPanelZoom: displayCurrentPanel called")
    local panel = self.current_panels[self.current_panel_index]
    if not panel then
        logger.warn("DynamicPanelZoom: No panel data found for index " .. self.current_panel_index)
        return false
    end

    -- Resolve first: a composite may downgrade to a normal lonely row (last page,
    -- empty next page), in which case we render it through the normal path below.
    if panel.composite then self:resolveComposite(panel) end
    local is_composite = panel.composite

    local image, custom_position, panel_aspect_ratio

    if is_composite then
        image, custom_position = self:renderCompositeUnit(panel)
        if not image then
            logger.warn("DynamicPanelZoom: Could not render composite unit")
            return false
        end
        panel_aspect_ratio = image:getWidth() / image:getHeight()
    else
        local page = self:getSafePageNumber()

        -- Get dimensions from document for consistent coordinate space
        local dim = self.ui.document:getNativePageDimensions(page) or self.ui.document:getPageSize(page)
        if not dim then
            logger.warn("DynamicPanelZoom: Could not get page dimensions")
            return false
        end
        logger.info(string.format("DynamicPanelZoom: Using document dimensions - w:%d, h:%d", dim.w, dim.h))

        -- Use helper function for center-preserving quantization with dynamic frame
        local margin = self.standard_margin_percent or 0.0
        local rect = self:panelToRect(panel, dim, margin)

        -- Calculate and log panel center coordinates
        local center = self:calculatePanelCenter(panel, dim)

        logger.info(string.format("DynamicPanelZoom: Panel rect - x:%d, y:%d, w:%d, h:%d", rect.x, rect.y, rect.w, rect.h))

        -- Create new image for the panel with document settings
        local t_draw = Perf:mark()
        local img, rotate, pos = self:drawPagePartWithSettings(page, rect, center, panel, dim)
        Perf:step("draw panel image", t_draw, "panel %d/%d on page %d",
            self.current_panel_index, #self.current_panels, page)
        if not img then
            logger.warn("DynamicPanelZoom: Could not draw page part")
            return false
        end
        image, custom_position = img, pos

        logger.info("DynamicPanelZoom: Successfully created panel image with document settings")

        -- Calculate panel aspect ratio for border logic
        local panel_w = panel.w * dim.w
        local panel_h = panel.h * dim.h
        panel_aspect_ratio = panel_w / panel_h
        logger.info(string.format("DynamicPanelZoom: Panel aspect ratio: %.3f", panel_aspect_ratio))
    end

    -- Reuse existing viewer if available instead of closing to prevent flash of full page
    if self._current_imgviewer then
        logger.info("DynamicPanelZoom: Updating existing PanelViewer")
        local t_update = Perf:mark()
        self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        self._current_imgviewer:updateCustomPosition(custom_position)
        self._current_imgviewer:updatePanelAspectRatio(panel_aspect_ratio)
        self._current_imgviewer:updateImage(image)
        -- The viewer now holds `image`; free any previously shown composite it
        -- displaced (nil for a normal panel frees a composite we were holding).
        self:_setDisplayedComposite(is_composite and image or nil)
        self._current_imgviewer:update(self:_panelRefreshMode())
        -- Only marks the widget dirty; the blit and the E-Ink refresh happen
        -- after we return, and are timed in PanelViewer:paintTo().
        Perf:step("viewer update (setDirty)", t_update)

        -- Start preloading the next panel after a short delay
        UIManager:scheduleIn(0.2, function()
            self:preloadNextPanel()
        end)
        return true
    end
    
    -- Create new PanelViewer instance with our custom implementation
    logger.info("DynamicPanelZoom: Creating new PanelViewer instance")
    local t_create = Perf:mark()
    local panel_viewer = PanelViewer:new{
        image = image,
        fullscreen = true,
        buttons_visible = false,
        reading_direction = self:getEffectiveReadingDirection(),
        custom_position = custom_position,  -- Pass custom position for center matching
        panel_aspect_ratio = panel_aspect_ratio,  -- Pass panel aspect ratio for border logic
        onTapRight = function() self:handleTapRight() end,
        onTapLeft = function() self:handleTapLeft() end,
        onClose = function() 
            self:closeViewer()
            -- Restore OCR when panel viewer is closed
            self:restoreOCR()
        end,
        onHold = function()
            self:switchToZoomMode()
        end,
    }
    
    self._current_imgviewer = panel_viewer
    logger.info("DynamicPanelZoom: Showing new PanelViewer")
    UIManager:show(panel_viewer)
    -- Record ownership of the composite buffer (if this first panel is one).
    self:_setDisplayedComposite(is_composite and image or nil)

    -- Entering panel view is a big visual change, so flash it if flashing is
    -- enabled at all -- this is also what resets the ghosting from the full page.
    self:_forceFullRefreshNext()
    local init_mode = self:_panelRefreshMode()
    UIManager:setDirty(panel_viewer, function()
        return init_mode, panel_viewer.dimen, Screen.sw_dithering  -- Enable dithering for E-ink
    end)
    
    Perf:step("viewer create+show", t_create, "refresh=%s", tostring(init_mode))
    logger.info("DynamicPanelZoom: New PanelViewer shown with flash-free refresh")
    
    -- Start preloading the next panel after a short delay
    UIManager:scheduleIn(0.2, function()
        self:preloadNextPanel()
    end)
    
    return true -- Success, new viewer created
end

-- Integrate reading direction options into existing panel zoom menu
function PanelZoomIntegration:setupPanelZoomMenuIntegration()
    -- Store original genPanelZoomMenu function
    if not self._original_genPanelZoomMenu and self.ui.highlight and self.ui.highlight.genPanelZoomMenu then
        self._original_genPanelZoomMenu = self.ui.highlight.genPanelZoomMenu
        
        -- Override genPanelZoomMenu to include our reading direction options
        self.ui.highlight.genPanelZoomMenu = function()
            local menu_items = self._original_genPanelZoomMenu(self.ui.highlight)
            
            -- Add reading direction submenu at the beginning
            table.insert(menu_items, 1, {
                text = _("Reading direction"),
                sub_item_table = {
                    {
                        text = _("Left-to-Right (LTR)"),
                        checked_func = function()
                            return self.reading_direction_override == "ltr" or self.reading_direction_override == nil
                        end,
                        callback = function()
                            self.reading_direction_override = "ltr"
                            logger.info("DynamicPanelZoom: Reading direction override set to LTR")
                            -- Clear all caches globally so next panel invocation re-sorts
                            self._panel_cache = {}
                            self.current_panels = {}
                            self._row_offsets = {}
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Right-to-Left (RTL)"),
                        checked_func = function()
                            return self.reading_direction_override == "rtl"
                        end,
                        callback = function()
                            self.reading_direction_override = "rtl"
                            logger.info("DynamicPanelZoom: Reading direction override set to RTL")
                            -- Clear all caches globally so next panel invocation re-sorts
                            self._panel_cache = {}
                            self.current_panels = {}
                            self._row_offsets = {}
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                },
                separator = true,
            })

            -- Add Tap Zone settings
            table.insert(menu_items, 2, {
                text = _("Next panel tap zone"),
                sub_item_table = {
                    {
                        text = _("Auto (based on reading direction)"),
                        checked_func = function() return self.panelzoom_tap_forward_zone == "auto" end,
                        callback = function()
                            self.panelzoom_tap_forward_zone = "auto"
                            logger.info("DynamicPanelZoom: Tap forward zone set to auto")
                        end,
                    },
                    {
                        text = _("Left side"),
                        checked_func = function() return self.panelzoom_tap_forward_zone == "left" end,
                        callback = function()
                            self.panelzoom_tap_forward_zone = "left"
                            logger.info("DynamicPanelZoom: Tap forward zone set to left")
                        end,
                    },
                    {
                        text = _("Right side"),
                        checked_func = function() return self.panelzoom_tap_forward_zone == "right" end,
                        callback = function()
                            self.panelzoom_tap_forward_zone = "right"
                            logger.info("DynamicPanelZoom: Tap forward zone set to right")
                        end,
                    },
                },
                separator = true,
            })

            -- Add Standard Panel options
            table.insert(menu_items, 3, {
                text = _("Standard panel settings"),
                sub_item_table = {
                    {
                        text = _("Show adjacent page content"),
                        checked_func = function() return self.show_adjacent_panels end,
                        callback = function()
                            self.show_adjacent_panels = not self.show_adjacent_panels
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Padding around panel"),
                        sub_item_table = {
                            {
                                text = _("0% (None)"),
                                checked_func = function() return self.standard_margin_percent == 0.0 end,
                                callback = function() self.standard_margin_percent = 0.0 end,
                            },
                            {
                                text = _("2% (Tight)"),
                                checked_func = function() return self.standard_margin_percent == 0.02 end,
                                callback = function() self.standard_margin_percent = 0.02 end,
                            },
                            {
                                text = _("5% (Normal)"),
                                checked_func = function() return self.standard_margin_percent == 0.05 end,
                                callback = function() self.standard_margin_percent = 0.05 end,
                            },
                            {
                                text = _("10% (Wide)"),
                                checked_func = function() return self.standard_margin_percent == 0.10 end,
                                callback = function() self.standard_margin_percent = 0.10 end,
                            },
                        }
                    }
                },
                separator = true,
            })
            
            -- Add Free Zoom options
            table.insert(menu_items, 4, {
                text = _("Hold-to-Zoom settings"),
                sub_item_table = {
                    {
                        text = _("Hold-to-Zoom padding"),
                        sub_item_table = {
                            {
                                text = _("2% (Tight)"),
                                checked_func = function() return self.zoom_margin_percent == 0.02 end,
                                callback = function() self.zoom_margin_percent = 0.02 end,
                            },
                            {
                                text = _("5% (Normal)"),
                                checked_func = function() return self.zoom_margin_percent == 0.05 end,
                                callback = function() self.zoom_margin_percent = 0.05 end,
                            },
                            {
                                text = _("10% (Wide)"),
                                checked_func = function() return self.zoom_margin_percent == 0.10 end,
                                callback = function() self.zoom_margin_percent = 0.10 end,
                            },
                            {
                                text = _("20% (Context)"),
                                checked_func = function() return self.zoom_margin_percent == 0.20 end,
                                callback = function() self.zoom_margin_percent = 0.20 end,
                            },
                        }
                    },
                    {
                        text = _("Initial zoom level"),
                        sub_item_table = {
                            {
                                text = _("Fit to screen (1.0x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.0 end,
                                callback = function() self.zoom_initial_scale = 1.0 end,
                            },
                            {
                                text = _("Slight Zoom (1.2x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.2 end,
                                callback = function() self.zoom_initial_scale = 1.2 end,
                            },
                            {
                                text = _("Medium Zoom (1.5x)"),
                                checked_func = function() return self.zoom_initial_scale == 1.5 end,
                                callback = function() self.zoom_initial_scale = 1.5 end,
                            },
                            {
                                text = _("Heavy Zoom (2.0x)"),
                                checked_func = function() return self.zoom_initial_scale == 2.0 end,
                                callback = function() self.zoom_initial_scale = 2.0 end,
                            },
                        }
                    },
                },
                separator = true,
            })
            
            -- Add Experimental features
            table.insert(menu_items, 5, {
                text = _("Experimental features"),
                sub_item_table = {
                    {
                        text = _("Experimental Panel Sorting (Z-pattern)"),
                        checked_func = function() return self.experimental_panel_sorting_enabled end,
                        callback = function()
                            self.experimental_panel_sorting_enabled = not self.experimental_panel_sorting_enabled
                            logger.info("DynamicPanelZoom: Experimental Panel Sorting set to " .. tostring(self.experimental_panel_sorting_enabled))
                            -- Invalidate cache so page is re-analyzed
                            self._panel_cache = {}
                            self.current_panels = {}
                            self._row_offsets = {}
                            self:refreshCurrentPanelIfActive()
                        end,
                    },
                    {
                        text = _("Performance tracing (log)"),
                        help_text = _("Write a detailed DPZPERF timing block to the log for every panel navigation. Off by default; enable only to diagnose slow page turns."),
                        checked_func = function() return Perf.enabled end,
                        callback = function()
                            Perf.enabled = not Perf.enabled
                            logger.info("DynamicPanelZoom: Performance tracing set to " .. tostring(Perf.enabled))
                            if G_reader_settings then
                                G_reader_settings:saveSetting("dpz_perf_tracing", Perf.enabled)
                            end
                        end,
                    },
                },
                separator = true,
            })

            -- Row view (lands at position 3; pushes the others down)
            table.insert(menu_items, 3, {
                text = _("Row view"),
                sub_item_table = {
                    {
                        text = _("Off (panel by panel)"),
                        checked_func = function() return self.row_mode == "panel" end,
                        callback = function() self:setRowMode("panel") end,
                    },
                    {
                        text = _("One row at a time"),
                        checked_func = function() return self.row_mode == "row" end,
                        callback = function() self:setRowMode("row") end,
                    },
                    {
                        text = _("Two rows at a time"),
                        checked_func = function() return self.row_mode == "two_rows" end,
                        callback = function() self:setRowMode("two_rows") end,
                    },
                    {
                        text = _("Auto (fit as many rows as the screen allows)"),
                        checked_func = function() return self.row_mode == "auto" end,
                        callback = function() self:setRowMode("auto") end,
                        separator = true,
                    },
                    {
                        text = _("Fill last row from next page"),
                        help_text = _("When a page ends on a single leftover row (two-row and auto modes), pull the first row of the next page up to fill the empty half."),
                        enabled_func = function()
                            return self.row_mode == "two_rows" or self.row_mode == "auto"
                        end,
                        checked_func = function() return self.cross_page_rows end,
                        callback = function()
                            self.cross_page_rows = not self.cross_page_rows
                            if G_reader_settings then
                                G_reader_settings:saveSetting("dpz_cross_page_rows", self.cross_page_rows)
                            end
                            self._row_offsets = {}
                            self:rebuildAndRedisplay()
                        end,
                    },
                    {
                        text = _("Landscape only"),
                        checked_func = function() return self.row_mode_landscape_only end,
                        callback = function()
                            self.row_mode_landscape_only = not self.row_mode_landscape_only
                            if G_reader_settings then
                                G_reader_settings:saveSetting("dpz_row_landscape_only", self.row_mode_landscape_only)
                            end
                            self:rebuildAndRedisplay()
                        end,
                    },
                },
                separator = true,
            })

            -- Screen refresh
            local function refresh_entry(label, n)
                return {
                    text = _(label),
                    checked_func = function() return self.full_refresh_every == n end,
                    callback = function()
                        self.full_refresh_every = n
                        self._panels_since_flash = 0
                        if G_reader_settings then
                            G_reader_settings:saveSetting("dpz_full_refresh_every", n)
                        end
                    end,
                }
            end
            table.insert(menu_items, 4, {
                text = _("Screen refresh"),
                sub_item_table = {
                    refresh_entry("Never flash", 0),
                    refresh_entry("Flash every panel", 1),
                    refresh_entry("Flash every 3 panels", 3),
                    refresh_entry("Flash every 6 panels", 6),
                    refresh_entry("Flash every 12 panels", 12),
                    {
                        text = _("Always flash on page turn"),
                        checked_func = function() return self.flash_on_page_turn end,
                        callback = function()
                            self.flash_on_page_turn = not self.flash_on_page_turn
                            if G_reader_settings then
                                G_reader_settings:saveSetting("dpz_flash_on_page_turn", self.flash_on_page_turn)
                            end
                        end,
                        separator = true,
                    },
                },
                separator = true,
            })

            return menu_items
        end
        
        logger.info("DynamicPanelZoom: Integrated reading direction options into panel zoom menu")
    end
end

-- Restore original panel zoom menu when plugin is disabled
function PanelZoomIntegration:restorePanelZoomMenu()
    -- Guard against multiple restoration calls
    if not self._original_genPanelZoomMenu then
        return -- Already restored or never stored
    end
    
    if self._original_genPanelZoomMenu and self.ui.highlight then
        self.ui.highlight.genPanelZoomMenu = self._original_genPanelZoomMenu
        self._original_genPanelZoomMenu = nil
        logger.info("DynamicPanelZoom: Restored original panel zoom menu")
    end
end

-- Refresh current panel if viewer is active (for reading direction changes)
function PanelZoomIntegration:refreshCurrentPanelIfActive()
    if self._current_imgviewer and self.integration_mode and #self.current_panels > 0 then
        logger.info("DynamicPanelZoom: Refreshing panel viewer with new reading direction")
        
        -- To ensure correct spatial flow, we must re-sort the panels
        -- by the new reading direction and map the current panel to its new index
        local old_panel = self.current_panels[self.current_panel_index]
        
        -- Import will automatically use the NEW reading direction and 
        -- either generate a new layout or pull it from the direction-specific cache.
        self:importToggleZoomPanels()
        
        -- Find the old panel in the newly sorted array so we stay on the same physical panel
        if old_panel and #self.current_panels > 0 then
            for i, p in ipairs(self.current_panels) do
                -- Compare coordinates (allowing tiny float variations)
                if math.abs(p.x - old_panel.x) < 0.001 and math.abs(p.y - old_panel.y) < 0.001 then
                    self.current_panel_index = i
                    break
                end
            end
        end
        
        -- Propagate reading direction immediately
        if self._current_imgviewer.updateReadingDirection then
            self._current_imgviewer:updateReadingDirection(self:getEffectiveReadingDirection())
        end
        self:displayCurrentPanel()
    end
end

function PanelZoomIntegration:setRowMode(mode)
    self.row_mode = mode
    if G_reader_settings then
        G_reader_settings:saveSetting("dpz_row_mode", mode)
    end
    logger.info("DynamicPanelZoom: row mode set to " .. tostring(mode))
    self:rebuildAndRedisplay()
end

-- Re-derive view units for the current page and redraw, keeping the reader
-- roughly where they were vertically on the page.
function PanelZoomIntegration:rebuildAndRedisplay()
    local old = self.current_panels and self.current_panels[self.current_panel_index]

    -- Invalidate first, and do it even when no viewer is open. onIntegratedPanelZoom
    -- skips importToggleZoomPanels() (and therefore buildViewUnits) whenever the page
    -- is unchanged and current_panels is non-empty, so without this a mode change
    -- picked from the menu would not take effect until the next page turn.
    self.current_panels = {}
    self.last_page_seen = -1
    -- Packing changed, so any leftover cross-page bookkeeping is invalid.
    self._row_offsets = {}
    self:cleanupPreloadedImage()

    if not self.integration_mode or not self._current_imgviewer then return end
    self:importToggleZoomPanels()
    if #self.current_panels == 0 then return end
    if old then
        local best, best_d = 1, math.huge
        for i, u in ipairs(self.current_panels) do
            local d = math.abs((u.y + u.h / 2) - (old.y + old.h / 2))
            if d < best_d then best, best_d = i, d end
        end
        self.current_panel_index = best
    end
    self.current_panel_index = math.min(self.current_panel_index, #self.current_panels)
    self:cleanupPreloadedImage()
    self:_forceFullRefreshNext()
    self:displayCurrentPanel()
end

-- Helper function: Calculate position to move panel center exactly to screen center
function PanelZoomIntegration:panelCenterToScreenPosition(panel, rect, dim, zoom)
    if not panel or not rect or not dim or not zoom then
        logger.warn("DynamicPanelZoom: Invalid parameters in panelCenterToScreenPosition")
        -- Fallback to screen center
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        return {
            x = math.floor(screen_w / 2),
            y = math.floor(screen_h / 2),
        }
    end
    
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- Absolute panel center (page space) from normalized JSON coordinates
    local panel_cx = (panel.x + panel.w / 2) * dim.w
    local panel_cy = (panel.y + panel.h / 2) * dim.h

    -- Center inside rect (page space)
    local cx_in_rect = panel_cx - rect.x
    local cy_in_rect = panel_cy - rect.y

    -- Scaled center (screen space)
    local cx_screen = cx_in_rect * zoom
    local cy_screen = cy_in_rect * zoom

    -- Translation to move center to screen center
    return {
        x = math.floor(screen_w / 2 - cx_screen + 0.5),
        y = math.floor(screen_h / 2 - cy_screen + 0.5),
    }
end

return PanelZoomIntegration
