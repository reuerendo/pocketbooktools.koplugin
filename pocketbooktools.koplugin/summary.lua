-- Summary dialog widget for displaying book information

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local ToggleSwitch = require("ui/widget/toggleswitch")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Screen = Device.screen

local SummaryDialog = InputContainer:extend{
    modal = true,
    is_always_active = true,
    ui = nil,
    doc_settings = nil,
    document = nil,
    file_path = nil,
}

function SummaryDialog:init()
    -- Initialize from ui parameter
    if self.ui then
        self.doc_settings = self.ui.doc_settings
        self.document = self.ui.document
        self.file_path = self.ui.document.file
    end
    
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } }
        }
    end
    
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(),
                    h = Screen:getHeight(),
                }
            }
        }
    end
    
    -- Load theme if available
    self.theme = nil
    local ok, PocketBookTheme = pcall(require, "theme")
    if ok and PocketBookTheme and PocketBookTheme:isEnabled() then
        self.theme = PocketBookTheme
        logger.dbg("SummaryDialog: PocketBookTheme loaded and enabled")
    end
    
    self:update()
end

function SummaryDialog:update()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    
    -- Container size: 80% of screen width
    local container_width = math.floor(screen_width * 0.8)
    local edge_padding = Size.padding.large * 2
    
    -- Cover dimensions (40% of container)
    local cover_width = math.floor(container_width * 0.4)
    local cover_height = math.floor(cover_width * 1.5)
    
    -- Info panel width (remaining space minus padding)
    local info_width = container_width - cover_width - edge_padding * 3
    
    -- Build cover
    local cover_widget = self:buildCoverWidget(cover_width, cover_height)
    
    -- Build info panel
    local info_panel = self:buildInfoPanel(info_width, cover_height)
    
    -- Main content (cover + info side by side)
    local main_content = HorizontalGroup:new{
        align = "top",
        FrameContainer:new{
            padding = 0,
            margin = 0,
            bordersize = 0,
            cover_widget,
        },
        HorizontalSpan:new{ width = edge_padding },
        info_panel,
    }
    
    -- Create frame (themed or default)
    local dialog_frame
    if self.theme then
        -- Use themed frame
        dialog_frame = self.theme:_createThemedFrame(main_content, {
            left = edge_padding,
            right = edge_padding,
            top = edge_padding,
            bottom = edge_padding
        })
    else
        -- Use default frame
        dialog_frame = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            padding = edge_padding,
            padding_top = edge_padding,
            padding_bottom = edge_padding,
            radius = Size.radius.window,
            width = container_width,
            main_content,
        }
    end
    
    -- Center on screen
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = screen_width,
            h = screen_height,
        },
        dialog_frame,
    }
end

function SummaryDialog:buildCoverWidget(cover_width, cover_height)
    local cover_image = self:getCoverImage()
    
    if cover_image then
        if type(cover_image) == "string" then
            -- File path
            return ImageWidget:new{
                file = cover_image,
                width = cover_width,
                height = cover_height,
                scale_factor = 0,
            }
        else
            -- BlitBuffer object
            return ImageWidget:new{
                image = cover_image,
                width = cover_width,
                height = cover_height,
                scale_factor = 0,
            }
        end
    else
        -- No cover - show placeholder
        return FrameContainer:new{
            width = cover_width,
            height = cover_height,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            bordersize = Size.border.thick,
            padding = 0,
            margin = 0,
            CenterContainer:new{
                dimen = Geom:new{
                    w = cover_width,
                    h = cover_height,
                },
                TextWidget:new{
                    text = _("No Cover"),
                    face = Font:getFace("cfont", 22),
                }
            }
        }
    end
end

function SummaryDialog:buildInfoPanel(info_width, cover_height)
    local title_font = Font:getFace("infofont", 24)
    local series_font = Font:getFace("xx_smallinfofont", 18)
    local author_font = Font:getFace("x_smallinfofont", 20)
    local info_font = Font:getFace("xx_smallinfofont", 18)
    
    -- Get metadata from doc_settings only
    local props = self.doc_settings:readSetting("doc_props") or {}
    local title = props.title or self.file_path:match("([^/]+)$")
    local authors = props.authors or _("Unknown Author")
    local series = props.series
    local series_index = props.series_index
    
    -- Get progress data
    local current_page, total_pages, percent, progress_ratio = self:getProgressData()
    
    logger.warn(string.format("SummaryDialog DEBUG: current_page=%s, total_pages=%s, percent=%s, ratio=%s", 
        tostring(current_page), tostring(total_pages), tostring(percent), tostring(progress_ratio)))
    
    local widgets = {}
    
    -- Title
    local title_widget = TextWidget:new{
        text = title,
        face = title_font,
        bold = true,
        max_width = info_width,
    }
    table.insert(widgets, title_widget)
    
    -- Series (if exists)
    local series_widget
    if series and series ~= "" then
        local series_text = series
        if series_index then
            series_text = series_text .. " — " .. tostring(series_index)
        end
        series_widget = TextWidget:new{
            text = series_text,
            face = series_font,
            max_width = info_width,
        }
    end
    
    -- Author
    local author_widget = TextWidget:new{
        text = authors,
        face = author_font,
        max_width = info_width,
    }
    
    -- Pages info line (pages read + percentage)
    local pages_text = string.format(_("%d of %d pages"), current_page, total_pages)
    
    local pages_widget = TextWidget:new{
        text = pages_text,
        face = info_font,
    }
    
    local percent_text = string.format("%d%%", percent)
    local percent_widget = TextWidget:new{
        text = percent_text,
        face = info_font,
    }
    
    local pages_line = HorizontalGroup:new{
        align = "center",
        pages_widget,
        HorizontalSpan:new{ 
            width = info_width - pages_widget:getSize().w - percent_widget:getSize().w 
        },
        percent_widget,
    }
    
    -- Progress bar (using ProgressWidget)
    logger.warn(string.format("SummaryDialog DEBUG: progress_ratio for ProgressWidget = %.4f", 
        progress_ratio))
    
    local progress_bar = ProgressWidget:new{
        width = info_width,
        height = Size.span.vertical_default,
        percentage = progress_ratio,
        margin_h = 0,
        margin_v = 0,
        bordersize = 0,
        radius = 0,
        fillcolor = Blitbuffer.COLOR_DARK_GRAY,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    
    -- Rating widget (stars)
    local rating_widget = self:buildRatingWidget(info_width)
    
    -- Status widget (reading/on hold/finished)
    local status_widget = self:buildStatusWidget(info_width)
    
    -- Calculate total fixed height with static spans
    local static_span_small = Size.span.vertical_default
    local static_span_between_series = Size.span.vertical_default
    
    local fixed_height = title_widget:getSize().h + static_span_small
    if series_widget then
        fixed_height = fixed_height + series_widget:getSize().h + static_span_between_series
    end
    fixed_height = fixed_height + author_widget:getSize().h
    fixed_height = fixed_height + pages_line:getSize().h + static_span_small
    fixed_height = fixed_height + progress_bar:getSize().h
    fixed_height = fixed_height + rating_widget:getSize().h
    fixed_height = fixed_height + Size.span.vertical_large
    fixed_height = fixed_height + status_widget:getSize().h
    
    -- Calculate available space for two flexible spans
    local remaining_height = cover_height - fixed_height
    local flexible_span_height = math.max(Size.span.vertical_large * 2, math.floor(remaining_height / 2))
    
    -- Build final layout with two flexible spans
    local final_widgets = {}
    table.insert(final_widgets, title_widget)
    table.insert(final_widgets, VerticalSpan:new{ width = static_span_small })
    
    if series_widget then
        table.insert(final_widgets, series_widget)
        table.insert(final_widgets, VerticalSpan:new{ width = static_span_between_series })
    end
    
    table.insert(final_widgets, author_widget)
    table.insert(final_widgets, VerticalSpan:new{ width = flexible_span_height })
    
    table.insert(final_widgets, pages_line)
    table.insert(final_widgets, VerticalSpan:new{ width = static_span_small })
    
    table.insert(final_widgets, progress_bar)
    table.insert(final_widgets, VerticalSpan:new{ width = flexible_span_height })
    
    table.insert(final_widgets, rating_widget)
    table.insert(final_widgets, VerticalSpan:new{ width = Size.span.vertical_large })
    
    table.insert(final_widgets, status_widget)
    
    return VerticalGroup:new{
        align = "left",
        unpack(final_widgets)
    }
end

function SummaryDialog:getProgressData()
    local pb_sync = self.doc_settings:readSetting("pocketbook_sync_progress")
    
    if pb_sync and pb_sync.ratio then
        local current_page = pb_sync.current_page or 0
        local total_pages = pb_sync.total_pages or 0
        local percent = pb_sync.percent or 0
        local ratio = pb_sync.ratio
        
        logger.dbg(string.format("SummaryDialog: Using saved progress - page %d/%d (%d%%, ratio=%.4f)", 
            current_page, total_pages, percent, ratio))
        
        return current_page, total_pages, percent, ratio
    end
    
    logger.warn("SummaryDialog: No progress data available")
    return 0, 0, 0, 0
end

function SummaryDialog:buildRatingWidget(info_width)
    local summary = self:getSummary()
    local rating = summary.rating or 0
    
    local stars_container = HorizontalGroup:new{ align = "center" }
    
    local star_base = Button:new{
        icon = "star.empty",
        bordersize = 0,
        radius = 0,
        margin = 0,
        enabled = true,
        show_parent = self,
    }
    
    -- Create star buttons
    for i = 1, rating do
        local star = star_base:new{
            icon = "star.full",
            callback = function()
                self:setStar(i, stars_container)
            end
        }
        table.insert(stars_container, star)
    end
    
    for i = rating + 1, 5 do
        local star = star_base:new{
            callback = function()
                self:setStar(i, stars_container)
            end
        }
        table.insert(stars_container, star)
    end
    
    return stars_container
end

function SummaryDialog:buildStatusWidget(info_width)
    local summary = self:getSummary()
    
    local config_wrapper = {
        dialog = self,
    }
    
    function config_wrapper:onConfigChoose(values, name, event, args, position)
        UIManager:tickAfterNext(function()
            self.dialog:onChangeBookStatus(args, position)
        end)
    end
    
    local switch = ToggleSwitch:new{
        width = info_width,
        toggle = { _("Reading"), _("On hold"), _("Finished"), },
        args = { "reading", "abandoned", "complete", },
        values = { 1, 2, 3, },
        enabled = true,
        config = config_wrapper,
    }
    
    local position = util.arrayContains(switch.args, summary.status) or 1
    switch:setPosition(position)
    
    return switch
end

function SummaryDialog:getSummary()
    local summary = self.doc_settings:readSetting("summary")
    if not summary then
        summary = {
            rating = 0,
            status = "reading",
            note = "",
            modified = os.date("%Y-%m-%d", os.time())
        }
    end
    return summary
end

function SummaryDialog:setStar(num, stars_container)
    stars_container:clear()
    
    local summary = self:getSummary()
    
    -- Toggle rating: if clicking the same rating, set to 0
    if num == summary.rating then
        num = 0
    end
    
    summary.rating = num
    summary.modified = os.date("%Y-%m-%d", os.time())
    
    self.doc_settings:saveSetting("summary", summary)
    self.doc_settings:flush()
    
    -- Invalidate BookInfoManager cache
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim then
        pcall(function() BookInfoManager:deleteBookInfo(self.file_path) end)
    end
    
    -- Recreate star buttons with updated rating
    local stars_group = HorizontalGroup:new{ align = "center" }
    
    local star_base = Button:new{
        icon = "star.empty",
        bordersize = 0,
        radius = 0,
        margin = 0,
        enabled = true,
        show_parent = self,
    }
    
    for i = 1, num do
        local star = star_base:new{
            icon = "star.full",
            callback = function()
                self:setStar(i, stars_container)
            end
        }
        table.insert(stars_group, star)
    end
    
    for i = num + 1, 5 do
        local star = star_base:new{
            callback = function()
                self:setStar(i, stars_container)
            end
        }
        table.insert(stars_group, star)
    end
    
    table.insert(stars_container, stars_group)
    UIManager:setDirty(self, "ui")
end

function SummaryDialog:onChangeBookStatus(args, position)
    local summary = self:getSummary()
    
    summary.status = args[position]
    summary.modified = os.date("%Y-%m-%d", os.time())
    
    self.doc_settings:saveSetting("summary", summary)
    self.doc_settings:flush()
    
    -- Invalidate BookInfoManager cache
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim then
        pcall(function() BookInfoManager:deleteBookInfo(self.file_path) end)
    end
    
    UIManager:setDirty(self, "ui")
end

function SummaryDialog:getCoverImage()
    -- Try cached cover from doc_settings
    local cover_file = self.doc_settings:readSetting("cover_file")
    if cover_file then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(cover_file, "mode") == "file" then
            logger.dbg("SummaryDialog: Using cached cover")
            return cover_file
        end
    end
    
    -- Try extracting from document
    if self.document then
        local ok, cover = pcall(function()
            return self.document:getCoverPageImage()
        end)
        
        if ok and cover then
            logger.dbg("SummaryDialog: Extracted cover from document")
            return cover
        end
    end
    
    logger.dbg("SummaryDialog: No cover found")
    return nil
end

function SummaryDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function SummaryDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function SummaryDialog:onTapClose(arg, ges)
    -- Close dialog if tapping outside
    if ges.pos:notIntersectWith(self[1][1].dimen) then
        self:onClose()
        return true
    end
    return false
end

function SummaryDialog:onClose()
    UIManager:close(self)
    return true
end

return SummaryDialog