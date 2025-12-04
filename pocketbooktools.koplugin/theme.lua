local Device = require("device")
local Font = require("ui/font")
local Screen = Device.screen
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local VerticalSpan = require("ui/widget/verticalspan")
local Utf8Proc = require("ffi/utf8proc")

local PocketBookTheme = {
    BORDER_SIZE = Screen:scaleBySize(4),
    RADIUS = Screen:scaleBySize(9),
    PADDING_HORIZONTAL = Screen:scaleBySize(12),
    PADDING_VERTICAL = Screen:scaleBySize(36),
    FONT_SIZE = 18,
    FONT_FACE = nil,
    BOTTOM_OFFSET_PERCENT = 0.1,
    ICON_SIZE = Screen:scaleBySize(120),
    MAX_WIDTH_PERCENT = 0.8,
    BUTTON_HEIGHT = 100,
    
    _original = {},
    _enabled = false,
}

-- ============================================================================
-- Initialization & State Management
-- ============================================================================

function PocketBookTheme:init()
    self._enabled = G_reader_settings:isTrue("pocketbook_theme_enabled")
    
    local roboto_paths = {
        "/usr/share/fonts/Roboto-Regular.ttf",
        "/mnt/ext1/system/fonts/Roboto-Regular.ttf",
        "/ebrmain/share/fonts/Roboto-Regular.ttf",
    }
    
    local roboto_found = false
    for _, path in ipairs(roboto_paths) do
        local file = io.open(path, "r")
        if file then
            file:close()
            self.FONT_FACE = "Roboto-Regular.ttf"
            self.FONT_PATH = path
            roboto_found = true
            logger.info("PocketBookTheme: Found Roboto font at", path)
            break
        end
    end
    
    if not roboto_found then
        logger.warn("PocketBookTheme: Roboto font not found, using infofont")
        self.FONT_FACE = "infofont"
        self.FONT_PATH = nil
    end
    
    if self._enabled then
        self:_applyTheme()
        logger.info("PocketBookTheme: Theme initialized and applied")
    else
        logger.info("PocketBookTheme: Theme initialized but not applied")
    end
end

function PocketBookTheme:enable()
    if not self._enabled then
        self._enabled = true
        G_reader_settings:saveSetting("pocketbook_theme_enabled", true)
        G_reader_settings:flush()
        self:_applyTheme()
        logger.info("PocketBookTheme: Theme enabled")
    end
end

function PocketBookTheme:disable()
    if self._enabled then
        self._enabled = false
        G_reader_settings:saveSetting("pocketbook_theme_enabled", false)
        G_reader_settings:flush()
        self:_restoreOriginal()
        logger.info("PocketBookTheme: Theme disabled")
    end
end

function PocketBookTheme:isEnabled()
    return self._enabled
end

-- ============================================================================
-- Main Patching System
-- ============================================================================

function PocketBookTheme:_applyTheme()
    -- CRITICAL: Apply global font replacement FIRST
    self:_applyGlobalFontReplacement()
    
    -- InfoMessage
    self:_patchWidget({
        module = "ui/widget/infomessage",
        key = "InfoMessage_init",
        pre_init = function(theme, widget)
            local screen_width = Screen:getSize().w
            local max_width = math.floor(screen_width * theme.MAX_WIDTH_PERCENT)
            widget.width = max_width - (theme.PADDING_HORIZONTAL * 2)
            widget.face = theme:_prepareFont()
            if theme.FONT_FACE ~= "infofont" then
                widget.monospace_font = false
            end
        end,
        temp_patches = {"SizeModule", "IconWidget"},
        frame_config = {
            position_at_bottom = true
        }
    })
    
    -- ConfirmBox
    self:_patchWidget({
        module = "ui/widget/confirmbox",
        key = "ConfirmBox_init",
        pre_init = function(theme, widget)
            local screen_width = Screen:getSize().w
            local max_width = math.floor(screen_width * theme.MAX_WIDTH_PERCENT)
            
            local icon_width = theme.ICON_SIZE
            local Size = require("ui/size")
            local span_width = Size.span.horizontal_default
            local frame_padding = theme.PADDING_HORIZONTAL * 2
            local available_content_width = max_width - frame_padding
            local calculated_text_width = available_content_width - icon_width - span_width - 20
            
            local TextBoxWidget = require("ui/widget/textboxwidget")
            if not theme._original.TextBoxWidget_new then
                theme._original.TextBoxWidget_new = TextBoxWidget.new
            end
            
            TextBoxWidget.new = function(class, o)
                o = o or {}
                if o.width and o.width > calculated_text_width then
                    logger.dbg("PocketBookTheme: Limiting TextBoxWidget width from", o.width, "to", calculated_text_width)
                    o.width = calculated_text_width
                end
                return theme._original.TextBoxWidget_new(class, o)
            end
            
            widget.face = theme:_prepareFont()
            
            logger.dbg("PocketBookTheme: ConfirmBox widths:")
            logger.dbg("  screen_width:", screen_width)
            logger.dbg("  max_width:", max_width)
            logger.dbg("  calculated_text_width:", calculated_text_width)
        end,
        temp_patches = {"SizeModule", "IconWidget"},
        post_init = function(theme, widget)
            local TextBoxWidget = require("ui/widget/textboxwidget")
            if theme._original.TextBoxWidget_new then
                TextBoxWidget.new = theme._original.TextBoxWidget_new
                theme._original.TextBoxWidget_new = nil
            end
            theme:_styleConfirmBoxButtons(widget)
        end,
        frame_config = function(theme)
            return {
                position_at_bottom = true,
                confirmbox_custom_layout = true
            }
        end
    })

	-- ButtonDialog
	self:_patchWidget({
		module = "ui/widget/buttondialog",
		key = "ButtonDialog_init",
		pre_init = function(theme, widget)
			local screen_width = Screen:getSize().w
			local max_width = math.floor(screen_width * theme.MAX_WIDTH_PERCENT)
			widget.width_factor = nil
			widget.width = max_width
			if widget.title then
				widget.title_face = theme:_prepareFont()
			end
			-- Set flag to skip button styling for ButtonDialog
			widget._skip_button_styling = true
		end,
		temp_patches = {"SizeModule"},
		frame_config = {
			padding = {left = 0, right = 0, top = 0, bottom = 0},
			cleanup_content = function(content, widget)
				if not widget.title then
					logger.dbg("PocketBookTheme: Removing empty title_group and separator")
					table.remove(content, 1)
					table.remove(content, 1)
					if content.resetLayout then
						content:resetLayout()
					end
				end
			end
		}
	})
    
    -- ButtonTable (only styling, no frame)
    self:_patchWidget({
        module = "ui/widget/buttontable",
        key = "ButtonTable_init",
        pre_init = function(theme, widget)
            theme:_styleButtons(widget)
        end,
        apply_frame = false
    })
end

function PocketBookTheme:_restoreOriginal()
    -- Restore global fonts FIRST
    self:_restoreGlobalFonts()
    
    -- Restore all patched widget methods
    for key, original_method in pairs(self._original) do
        if key:match("_init$") then
            local module_name = key:gsub("_init$", ""):gsub("([A-Z])", function(c) 
                return (c == key:sub(1,1)) and c:lower() or "_" .. c:lower()
            end)
            
            local module_map = {
                info_message = "ui/widget/infomessage",
                confirm_box = "ui/widget/confirmbox",
                button_table = "ui/widget/buttontable",
                button_dialog = "ui/widget/buttondialog",
            }
            
            local module_path = module_map[module_name]
            if module_path then
                local WidgetModule = require(module_path)
                WidgetModule.init = original_method
                logger.dbg("PocketBookTheme: Restored", key)
            end
        end
    end
    
    self._original = {}
    logger.info("PocketBookTheme: All widgets restored to original state")
end

-- ============================================================================
-- Global Font Replacement System
-- ============================================================================

function PocketBookTheme:_applyGlobalFontReplacement()
    if self.FONT_FACE == "infofont" or not self.FONT_PATH then
        logger.warn("PocketBookTheme: Roboto not available, skipping global font replacement")
        return
    end
    
    -- Create symlink for Roboto fonts
    self:_createRobotoSymlinks()
    
    -- Backup original fontmap
    if not self._original.fontmap then
        self._original.fontmap = {}
        for key, value in pairs(Font.fontmap) do
            self._original.fontmap[key] = value
        end
        logger.dbg("PocketBookTheme: Backed up original fontmap")
    end
    
    -- Replace ALL UI fonts with Roboto
    local roboto_regular = "Roboto-Regular.ttf"
    local roboto_bold = "Roboto-Bold.ttf"
    
    -- Main content fonts
    Font.fontmap.cfont = roboto_regular
    
    -- Title fonts (use bold)
    Font.fontmap.tfont = roboto_bold
    Font.fontmap.smalltfont = roboto_bold
    Font.fontmap.x_smalltfont = roboto_bold
    
    -- Footer fonts
    Font.fontmap.ffont = roboto_regular
    Font.fontmap.smallffont = roboto_regular
    Font.fontmap.largeffont = roboto_regular
    
    -- Page fonts
    Font.fontmap.pgfont = roboto_regular
    
    -- Shortcut fonts
    Font.fontmap.scfont = roboto_regular
    
    -- Reader info font
    Font.fontmap.rifont = roboto_regular
    
    -- Help page font
    Font.fontmap.hpkfont = roboto_regular
    
    -- Header font
    Font.fontmap.hfont = roboto_regular
    
    -- Info fonts (меню, диалоги, уведомления)
    -- Font.fontmap.infont = roboto_regular
    -- Font.fontmap.smallinfont = roboto_regular
    Font.fontmap.infofont = roboto_regular
    Font.fontmap.smallinfofont = roboto_regular
    Font.fontmap.smallinfofontbold = roboto_bold
    Font.fontmap.x_smallinfofont = roboto_regular
    Font.fontmap.xx_smallinfofont = roboto_regular
    
    logger.info("PocketBookTheme: Global font replacement applied - all UI fonts set to Roboto")
    
    -- Log all replaced fonts
    logger.dbg("PocketBookTheme: Font replacements:")
    for key, value in pairs(Font.fontmap) do
        if value == roboto_regular or value == roboto_bold then
            logger.dbg("  ", key, "->", value)
        end
    end
end

function PocketBookTheme:_restoreGlobalFonts()
    if self._original.fontmap then
        for key, value in pairs(self._original.fontmap) do
            Font.fontmap[key] = value
        end
        self._original.fontmap = nil
        logger.info("PocketBookTheme: Global fonts restored to original")
    end
end

function PocketBookTheme:_createRobotoSymlinks()
    local font_dir = "./fonts"
    
    -- Создаём симлинки для Roboto Regular и Bold
    local fonts_to_link = {
        {name = "Roboto-Regular.ttf", source = self.FONT_PATH},
        {name = "Roboto-Bold.ttf", source = self.FONT_PATH:gsub("Regular", "Bold")}
    }
    
    for _, font_info in ipairs(fonts_to_link) do
        local font_link = font_dir .. "/" .. font_info.name
        local link_exists = io.open(font_link, "r")
        
        if not link_exists then
            -- Проверяем существование исходного файла
            local source_exists = io.open(font_info.source, "r")
            if source_exists then
                source_exists:close()
                os.execute("ln -sf " .. font_info.source .. " " .. font_link)
                logger.dbg("PocketBookTheme: Created symlink", font_link, "->", font_info.source)
            else
                logger.warn("PocketBookTheme: Source font not found:", font_info.source)
            end
        else
            link_exists:close()
            logger.dbg("PocketBookTheme: Symlink already exists:", font_link)
        end
    end
end

-- ============================================================================
-- Universal widget patching method
-- ============================================================================

function PocketBookTheme:_patchWidget(config)
    local Widget = require(config.module)
    local key = config.key
    
    if not self._original[key] then
        self._original[key] = Widget.init
    end
    
    local theme = self
    
    Widget.init = function(widget)
        if config.pre_init then
            config.pre_init(theme, widget)
        end
        
        if config.temp_patches then
            for _, patch_name in ipairs(config.temp_patches) do
                local patch_method = "_patch" .. patch_name
                if theme[patch_method] then
                    theme[patch_method](theme)
                end
            end
        end
        
        theme._original[key](widget)
        
        if config.temp_patches then
            for _, patch_name in ipairs(config.temp_patches) do
                local unpatch_method = "_unpatch" .. patch_name
                if theme[unpatch_method] then
                    theme[unpatch_method](theme)
                end
            end
        end
        
        if config.post_init then
            config.post_init(theme, widget)
        end
        
        if config.apply_frame ~= false then
            theme:_applyThemedFrame(widget, config.frame_config or {})
        end
    end
    
    logger.dbg("PocketBookTheme:", config.module, "patched")
end

function PocketBookTheme:_applyThemedFrame(widget, config)
    if type(config) == "function" then
        config = config(self)
    end
    config = config or {}
    
    local container = widget.movable or widget
    if not container or not container[1] then
        logger.warn("PocketBookTheme: Cannot apply themed frame - no container found")
        return false
    end
    
    local old_frame = container[1]
    local content = old_frame[1]
    
    if config.cleanup_content then
        config.cleanup_content(content, widget)
    end
    
    -- Special handling for ConfirmBox custom layout
    if config.confirmbox_custom_layout and content and content.align == "left" then
        local buttons_widget = nil
        local buttons_index = nil
        local vspan_before_buttons = nil
        local vspan_index = nil
        
        -- Find ButtonTable and VerticalSpan before it
        for i = #content, 1, -1 do
            local item = content[i]
            if item and type(item) == "table" and item.buttons then
                buttons_widget = item
                buttons_index = i
                if i > 1 then
                    local prev_item = content[i - 1]
                    if prev_item and prev_item.width and not prev_item.buttons and not prev_item.text then
                        vspan_before_buttons = prev_item
                        vspan_index = i - 1
                    end
                end
                break
            end
        end
        
        if buttons_widget and buttons_index then
            -- Calculate target width
            local screen_width = Screen:getSize().w
            local max_width = math.floor(screen_width * self.MAX_WIDTH_PERCENT)
            local buttons_width = max_width - (self.BORDER_SIZE * 2) - 2  -- 2 for inner border
            
            -- Remove ButtonTable and VerticalSpan from content
            table.remove(content, buttons_index)
            if vspan_index then
                table.remove(content, vspan_index)
            end
            
            if content.resetLayout then
                content:resetLayout()
            end
            
            -- Recreate ButtonTable with correct width
            if buttons_widget.free then
                buttons_widget:free()
            end
            
            local ButtonTable = require("ui/widget/buttontable")
            local new_buttons = ButtonTable:new{
                width = buttons_width,
                buttons = buttons_widget.buttons,
                zero_sep = buttons_widget.zero_sep,
                show_parent = buttons_widget.show_parent,
            }
            
            logger.dbg("PocketBookTheme: ButtonTable width set to:", buttons_width)
            
            -- Add horizontal padding to content
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan = require("ui/widget/horizontalspan")
            local padded_content = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = self.PADDING_HORIZONTAL },
                content,
                HorizontalSpan:new{ width = self.PADDING_HORIZONTAL },
            }
            
            -- Create new vertical group with padded content and full-width buttons
            local VerticalGroup = require("ui/widget/verticalgroup")
            local VerticalSpan = require("ui/widget/verticalspan")
            local combined_content = VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = self.PADDING_VERTICAL },
                padded_content,
                VerticalSpan:new{ width = self.PADDING_VERTICAL },
                new_buttons,
            }
            
            -- Create themed frame
            local inner_radius = math.max(0, self.RADIUS - self.BORDER_SIZE)
            local inner_frame = FrameContainer:new{
                radius = inner_radius,
                bordersize = 1,
                color = Blitbuffer.COLOR_BLACK,
                background = Blitbuffer.COLOR_WHITE,
                padding = 0,
                combined_content
            }
            
            local outer_frame = FrameContainer:new{
                radius = self.RADIUS,
                bordersize = self.BORDER_SIZE,
                color = Blitbuffer.COLOR_BLACK,
                background = Blitbuffer.COLOR_BLACK,
                padding = 0,
                inner_frame,
            }
            
            container[1] = outer_frame
            
            if config.position_at_bottom then
                self:_positionAtBottom(widget)
            end
            
            logger.dbg("PocketBookTheme: Applied ConfirmBox custom layout with full-width buttons")
            return true
        end
    end
    
    -- Standard frame application for other widgets
    local padding = config.padding or {
        left = self.PADDING_HORIZONTAL,
        right = self.PADDING_HORIZONTAL,
        top = self.PADDING_VERTICAL,
        bottom = self.PADDING_VERTICAL
    }
    
    local new_frame = self:_createThemedFrame(content, padding)
    container[1] = new_frame
    
    if config.position_at_bottom then
        self:_positionAtBottom(widget)
    end
    
    logger.dbg("PocketBookTheme: Applied themed frame, width:", new_frame:getSize().w)
    return true
end

-- ============================================================================
-- Helper Methods: Font & Frame
-- ============================================================================

function PocketBookTheme:_prepareFont()
    if self.FONT_FACE == "infofont" or not self.FONT_PATH then
        return Font:getFace("infofont", self.FONT_SIZE)
    end

    local font_dir = "./fonts"
    local font_link = font_dir .. "/" .. self.FONT_FACE
    
    local link_exists = io.open(font_link, "r")
    if not link_exists then
        os.execute("ln -sf " .. self.FONT_PATH .. " " .. font_link)
        logger.dbg("PocketBookTheme: Created symlink", font_link, "->", self.FONT_PATH)
    else
        link_exists:close()
    end
    
    local status, new_face = pcall(Font.getFace, Font, self.FONT_FACE, self.FONT_SIZE)
    if status and new_face then
        return new_face
    else
        logger.warn("PocketBookTheme: Using infofont fallback", tostring(new_face))
        return Font:getFace("infofont", self.FONT_SIZE)
    end
end

function PocketBookTheme:_createThemedFrame(content, padding_config)
    local inner_radius = math.max(0, self.RADIUS - self.BORDER_SIZE)
    local p_left = padding_config.left or self.PADDING_HORIZONTAL
    local p_right = padding_config.right or self.PADDING_HORIZONTAL
    local p_top = padding_config.top or self.PADDING_VERTICAL
    local p_bottom = padding_config.bottom or self.PADDING_VERTICAL

    local inner_frame = FrameContainer:new{
        radius = inner_radius,
        bordersize = 1,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        padding_left = p_left,
        padding_right = p_right,
        padding_top = p_top,
        padding_bottom = p_bottom,
        content
    }
    
    local outer_frame = FrameContainer:new{
        radius = self.RADIUS,
        bordersize = self.BORDER_SIZE,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_BLACK,
        padding = 0,
        inner_frame,
    }

    return outer_frame
end

function PocketBookTheme:_positionAtBottom(widget)
    if widget[1] then
        local screen_size = Screen:getSize()
        local bottom_margin = math.floor(screen_size.h * self.BOTTOM_OFFSET_PERCENT)
        
        widget[1] = BottomContainer:new{
            dimen = Geom:new{
                w = screen_size.w,
                h = screen_size.h - bottom_margin,
            },
            widget.movable,
        }
    end
end

-- ============================================================================
-- Helper Methods: Button Styling
-- ============================================================================

function PocketBookTheme:_styleButtons(button_table)
    if not button_table or not button_table.buttons then
        return
    end
    
    -- Check if we should skip uppercase transformation (for ButtonDialog)
    local skip_uppercase = button_table.show_parent and button_table.show_parent._skip_button_styling
    
    for _, row in ipairs(button_table.buttons) do
        for _, btn in ipairs(row) do
            if btn.text and not skip_uppercase then
                -- Use KOReader's built-in UTF-8 uppercase function
                btn.text = Utf8Proc.uppercase_dumb(btn.text)
            end
            if not btn.height then
                btn.height = self.BUTTON_HEIGHT
            end
            
            if self.FONT_FACE ~= "infofont" and self.FONT_PATH then
                btn.font_face = self.FONT_FACE
                btn.font_bold = false
            else
                btn.font_bold = false
            end
        end
    end
end

function PocketBookTheme:_styleConfirmBoxButtons(widget)
    local inner_frame_obj = widget.movable and widget.movable[1]
    if not inner_frame_obj then
        return
    end
    
    local vertical_group = inner_frame_obj[1]
    if not vertical_group or not vertical_group.align then
        return
    end
    
    local button_table, button_table_index
    for i = #vertical_group, 1, -1 do
        local item = vertical_group[i]
        if item and type(item) == "table" and item.buttons then
            button_table = item
            button_table_index = i
            logger.dbg("  Found ButtonTable at index:", i)
            break
        end
    end
    
    if not button_table then
        return
    end
    
    self:_styleButtons(button_table)
    
    if button_table.free then
        button_table:free()
    end
    local ButtonTable = require("ui/widget/buttontable")
    local new_button_table = ButtonTable:new{
        width = button_table.width,
        buttons = button_table.buttons,
        zero_sep = button_table.zero_sep,
        show_parent = button_table.show_parent,
    }
    vertical_group[button_table_index] = new_button_table
    
    if button_table_index and button_table_index > 1 then
        local prev_item = vertical_group[button_table_index - 1]
        local is_our_span = prev_item and prev_item.width == self.PADDING_VERTICAL 
            and not prev_item.buttons and not prev_item.text
        
        if not is_our_span then
            table.insert(vertical_group, button_table_index, 
                VerticalSpan:new{ width = self.PADDING_VERTICAL })
            logger.dbg("  Inserted VerticalSpan before ButtonTable")
            if vertical_group.resetLayout then 
                vertical_group:resetLayout() 
            end
        end
    end
end

-- ============================================================================
-- Temporary Patches (Size, IconWidget, etc.)
-- ============================================================================

function PocketBookTheme:_patchSizeModule()
    if not self._original.Size then
        self._original.Size = {
            radius_window = Size.radius.window,
            border_window = Size.border.window,
        }
        Size.radius.window = self.RADIUS
        Size.border.window = self.BORDER_SIZE
    end
end

function PocketBookTheme:_unpatchSizeModule()
    if self._original.Size then
        Size.radius.window = self._original.Size.radius_window
        Size.border.window = self._original.Size.border_window
        self._original.Size = nil
    end
end

function PocketBookTheme:_patchIconWidget()
    if not self._original.IconWidget_new then
        local IconWidget = require("ui/widget/iconwidget")
        self._original.IconWidget_new = IconWidget.new
        
        local icon_size = self.ICON_SIZE
        
        IconWidget.new = function(class, o)
            o = o or {}
            if not o.width and not o.height then
                o.width = icon_size
                o.height = icon_size
                o.scale_factor = 0
            end
            return PocketBookTheme._original.IconWidget_new(class, o)
        end
    end
end

function PocketBookTheme:_unpatchIconWidget()
    if self._original.IconWidget_new then
        local IconWidget = require("ui/widget/iconwidget")
        IconWidget.new = self._original.IconWidget_new
        self._original.IconWidget_new = nil
    end
end

return PocketBookTheme