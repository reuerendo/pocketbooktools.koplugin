local Device = require("device")
local Screen = Device.screen
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local FrameContainer = require("ui/widget/container/framecontainer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local lfs = require("libs/libkoreader-lfs")

local PocketBookTheme = {
    BORDER_SIZE = Screen:scaleBySize(4),
    RADIUS = Screen:scaleBySize(9),
    MAX_WIDTH_PERCENT = 0.8,
    BOTTOM_OFFSET_PERCENT = 0.1,
    ICON_SIZE = Screen:scaleBySize(120),
    FONT_SIZE = 18,
    TEXT_PADDING_VERTICAL = Screen:scaleBySize(24),
    BUTTON_HEIGHT = 110,
    
    FONT_REGULAR = nil,
    FONT_BOLD = nil,
    
    FONT_PATHS = {
        system = "/system/fonts",
        koreader = "fonts",
    },
    
    -- Constant list of font keys to replace
    FONT_KEYS_TO_REPLACE = {
        "cfont", "tfont", "ffont", "smallfont", "x_smallfont", "infofont",
        "smallinfofont", "largefont", "smalltfont", "x_smalltfont",
        "smallffont", "largeffont", "rifont",
    },
    
    -- Precompiled pattern for monospace font detection
    MONOSPACE_PATTERN = "[Mm]ono",
    MONOSPACE_PATTERNS = {"[Cc]ode", "[Cc]ourier"},
    
    _original = {},
    _enabled = false,
    _processed_widgets = nil, -- Will be weak table
    _hooked_classes = {},
    _original_fontmap = {},
    _cached_modules = {},
    
    -- Cached computed values
    _cached_screen_width = nil,
    _cached_max_content_width = nil,
    _cached_available_content_width = nil,
    _cached_text_width = nil,
    _cached_inner_radius = nil,
    _cached_custom_face = nil,
}

-- Initialization & State Management

function PocketBookTheme:init()
    self:_resolveFontPaths()
    self._enabled = G_reader_settings:isTrue("pocketbook_theme_enabled")
    
    -- Initialize weak table for processed widgets
    self._processed_widgets = setmetatable({}, {__mode = "k"})
    
    -- Precompute cached values
    self:_computeCachedValues()
    
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

-- Cached Values Computation

function PocketBookTheme:_computeCachedValues()
    local screen_size = Screen:getSize()
    self._cached_screen_width = screen_size.w
    
    self._cached_max_content_width = math.floor(self._cached_screen_width * self.MAX_WIDTH_PERCENT)
    
    local frame_padding = (self.BORDER_SIZE * 2) + 2
    self._cached_available_content_width = self._cached_max_content_width - frame_padding
    
    local span_width = Size.span.horizontal_default or 0
    self._cached_text_width = self._cached_available_content_width - self.ICON_SIZE - span_width - 20
    
    self._cached_inner_radius = math.max(0, self.RADIUS - self.BORDER_SIZE)
    
    -- Cache custom font face
    if self.FONT_REGULAR then
        local Font = self:_requireCached("ui/font")
        self._cached_custom_face = Font:getFace(self.FONT_REGULAR, self.FONT_SIZE)
    end
end

-- Cached require function

function PocketBookTheme:_requireCached(module_path)
    if not self._cached_modules[module_path] then
        self._cached_modules[module_path] = require(module_path)
    end
    return self._cached_modules[module_path]
end

-- Font Path Resolution

function PocketBookTheme:_resolveFontPaths()
    local roboto_regular = "Roboto-Regular.ttf"
    local roboto_bold = "Roboto-Bold.ttf"
    
    local system_regular = self.FONT_PATHS.system .. "/" .. roboto_regular
    local system_bold = self.FONT_PATHS.system .. "/" .. roboto_bold
    
    local koreader_regular = self.FONT_PATHS.koreader .. "/" .. roboto_regular
    local koreader_bold = self.FONT_PATHS.koreader .. "/" .. roboto_bold
    
    -- Check KOReader fonts first
    if self:_fileExists(koreader_regular) and self:_fileExists(koreader_bold) then
        self.FONT_REGULAR = koreader_regular
        self.FONT_BOLD = koreader_bold
        logger.info("PocketBookTheme: Using fonts from KOReader fonts folder")
        return true
    end
    
    -- Check system fonts
    local system_fonts_exist = self:_fileExists(system_regular) and self:_fileExists(system_bold)
    
    if system_fonts_exist then
        -- Try to create symlinks
        if self:_createSymlinks(system_regular, system_bold, koreader_regular, koreader_bold) then
            self.FONT_REGULAR = koreader_regular
            self.FONT_BOLD = koreader_bold
            logger.info("PocketBookTheme: Created symlinks to system fonts")
            return true
        end
        
        -- If symlinks failed, use system fonts directly
        self.FONT_REGULAR = system_regular
        self.FONT_BOLD = system_bold
        logger.info("PocketBookTheme: Using system fonts from /system/fonts")
        return true
    end
    
    logger.warn("PocketBookTheme: Roboto fonts not found. Font changes will be disabled.")
    logger.warn("PocketBookTheme: Please install Roboto fonts or create symlinks manually:")
    logger.warn("  ln -s /system/fonts/Roboto-Regular.ttf fonts/Roboto-Regular.ttf")
    logger.warn("  ln -s /system/fonts/Roboto-Bold.ttf fonts/Roboto-Bold.ttf")
    
    return false
end

function PocketBookTheme:_fileExists(path)
    local mode = lfs.attributes(path, "mode")
    return mode == "file" or mode == "link"
end

function PocketBookTheme:_createSymlinks(src_regular, src_bold, dst_regular, dst_bold)
    local fonts_dir = self.FONT_PATHS.koreader
    local mode = lfs.attributes(fonts_dir, "mode")
    if mode ~= "directory" then
        logger.warn("PocketBookTheme: fonts directory does not exist:", fonts_dir)
        return false
    end
    
    local success = true
    
    if not self:_fileExists(dst_regular) then
        local cmd = string.format('ln -s "%s" "%s"', src_regular, dst_regular)
        if os.execute(cmd) ~= 0 then
            logger.warn("PocketBookTheme: Failed to create symlink for regular font")
            success = false
        end
    end
    
    if not self:_fileExists(dst_bold) then
        local cmd = string.format('ln -s "%s" "%s"', src_bold, dst_bold)
        if os.execute(cmd) ~= 0 then
            logger.warn("PocketBookTheme: Failed to create symlink for bold font")
            success = false
        end
    end
    
    return success
end

-- Theme Application

function PocketBookTheme:_applyTheme()
    if self.FONT_REGULAR and self.FONT_BOLD then
        self:_applyFontChanges()
    end
    self:_hookWidgetClasses()
    self:_hookInfoMessageAndConfirmBox()
    self:_hookButtonTable()
    self:_hookUIManagerShow()
    logger.info("PocketBookTheme: Theme applied with fonts and widget hooks")
end

function PocketBookTheme:_restoreOriginal()
    self:_restoreFonts()
    self:_unhookInfoMessageAndConfirmBox()
    self:_unhookButtonTable()
    
    for class_name, original_new in pairs(self._hooked_classes) do
        local widget_class = self._cached_modules[class_name]
        if widget_class then
            widget_class.new = original_new
        end
    end
    self._hooked_classes = {}
    
    if self._original.UIManager_show then
        local UIManager = self:_requireCached("ui/uimanager")
        UIManager.show = self._original.UIManager_show
        self._original.UIManager_show = nil
    end
    
    if self._original.UIManager_close then
        local UIManager = self:_requireCached("ui/uimanager")
        UIManager.close = self._original.UIManager_close
        self._original.UIManager_close = nil
    end
    
    if self._original.DictQuickLookup_new then
        local DictQuickLookup = self:_requireCached("ui/widget/dictquicklookup")
        DictQuickLookup.new = self._original.DictQuickLookup_new
        self._original.DictQuickLookup_new = nil
    end
    
    self._processed_widgets = setmetatable({}, {__mode = "k"})
    logger.info("PocketBookTheme: Theme restored")
end

-- Font Management

function PocketBookTheme:_isMonospaceFont(font_name)
    -- Check for monospace patterns
    if font_name:find(self.MONOSPACE_PATTERN) then
        return true
    end
    
    for _, pattern in ipairs(self.MONOSPACE_PATTERNS) do
        if font_name:find(pattern) then
            return true
        end
    end
    
    -- Check for Droid Sans Mono
    if font_name:find("Droid") and font_name:find("Sans") and font_name:find(self.MONOSPACE_PATTERN) then
        return true
    end
    
    return false
end

function PocketBookTheme:_applyFontChanges()
    local Font = self:_requireCached("ui/font")
    
    if not Font.fontmap then
        logger.warn("PocketBookTheme: Font.fontmap not available")
        return false
    end
    
    -- Save original fontmap efficiently
    if not next(self._original_fontmap) then
        for key, value in pairs(Font.fontmap) do
            self._original_fontmap[key] = value
        end
    end
    
    local changed_count = 0
    
    for _, key in ipairs(self.FONT_KEYS_TO_REPLACE) do
        local original = Font.fontmap[key]
        if original and not self:_isMonospaceFont(original) then
            local is_bold = original:find("[Bb]old")
            Font.fontmap[key] = is_bold and self.FONT_BOLD or self.FONT_REGULAR
            changed_count = changed_count + 1
        end
    end
    
    if changed_count > 0 then
        logger.info(string.format("PocketBookTheme: Changed %d UI fonts to Roboto", changed_count))
        return true
    else
        logger.warn("PocketBookTheme: No fonts were changed")
        return false
    end
end

function PocketBookTheme:_restoreFonts()
    if not next(self._original_fontmap) then
        return
    end
    
    local Font = self:_requireCached("ui/font")
    
    if not Font.fontmap then
        logger.warn("PocketBookTheme: Font.fontmap not available for restore")
        return
    end
    
    local restored_count = 0
    
    for key, original_value in pairs(self._original_fontmap) do
        if Font.fontmap[key] then
            Font.fontmap[key] = original_value
            restored_count = restored_count + 1
        end
    end
    
    self._original_fontmap = {}
    logger.info(string.format("PocketBookTheme: Restored %d fonts to original", restored_count))
end

-- Widget Class Hooks

function PocketBookTheme:_hookWidgetClasses()
    local widget_classes = {
        "ui/widget/buttondialog",
        "ui/widget/inputdialog",
        "ui/widget/multiinputdialog",
    }
    
    local max_content_width = self._cached_max_content_width
    local border_size = self.BORDER_SIZE
    local theme = self
    
    for _, class_path in ipairs(widget_classes) do
        local success, widget_class = pcall(require, class_path)
        if success and widget_class and widget_class.new then
            if not self._hooked_classes[class_path] then
                self._cached_modules[class_path] = widget_class
                self._hooked_classes[class_path] = widget_class.new
                
                widget_class.new = function(class, args)
                    local content_width = max_content_width - (border_size * 2) - 2
                    
                    if not args.width or args.width > content_width then
                        args.width = content_width
                    end
                    
                    if class_path == "ui/widget/buttondialog" and args.buttons then
                        theme:_styleButtonsForWidget(args.buttons, "ButtonDialog")
                    end
                    
                    return theme._hooked_classes[class_path](class, args)
                end
            end
        end
    end
    
    self:_hookDictQuickLookup()
end

function PocketBookTheme:_hookDictQuickLookup()
    local success, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if not success or not DictQuickLookup then
        logger.warn("PocketBookTheme: Could not load DictQuickLookup")
        return
    end
    
    if not self._original.DictQuickLookup_new then
        self._cached_modules["ui/widget/dictquicklookup"] = DictQuickLookup
        self._original.DictQuickLookup_new = DictQuickLookup.new
    end
    
    local max_width = self._cached_max_content_width
    local border_size = self.BORDER_SIZE
    local theme = self
    
    DictQuickLookup.new = function(class, args)
        local frame_overhead = (border_size * 2) + 2
        args.width = max_width - frame_overhead
        
        return theme._original.DictQuickLookup_new(class, args)
    end
    
    logger.info("PocketBookTheme: Hooked DictQuickLookup")
end

-- ButtonTable Hook

function PocketBookTheme:_isCalledFromButtonDialog()
    -- Check stack efficiently using debug.getinfo
    for level = 2, 10 do
        local info = debug.getinfo(level, "S")
        if not info then
            break
        end
        if info.source and info.source:find("buttondialog") then
            return true
        end
    end
    return false
end

function PocketBookTheme:_hookButtonTable()
    local Button = self:_requireCached("ui/widget/button")
    local ButtonTable = self:_requireCached("ui/widget/buttontable")
    local Utf8Proc = require("ffi/utf8proc")
    
    if not self._original.Button_new then
        self._original.Button_new = Button.new
    end
    
    if not self._original.ButtonTable_new_global then
        self._original.ButtonTable_new_global = ButtonTable.new
    end
    
    local theme = self
    local button_height = self.BUTTON_HEIGHT
    
    ButtonTable.new = function(class, args)
        if args.buttons then
            local is_buttondialog = theme:_isCalledFromButtonDialog()
            
            for _, row in ipairs(args.buttons) do
                for _, btn in ipairs(row) do
                    -- Apply uppercase to all buttons except ButtonDialog
                    if btn.text and not is_buttondialog then
                        btn.text = Utf8Proc.uppercase_dumb(btn.text)
                    end
                    btn.font_bold = false
                end
            end
        end
        
        return theme._original.ButtonTable_new_global(class, args)
    end
    
    Button.new = function(class, args)
        if args.bordersize == 0 and args.margin == 0 then
            args.radius = 0
            args.padding = 0
            args.padding_h = 0
            args.padding_v = 0
            args.height = button_height
        end
        
        return theme._original.Button_new(class, args)
    end
    
    logger.info("PocketBookTheme: ButtonTable button styling hooked")
end

function PocketBookTheme:_unhookButtonTable()
    if self._original.Button_new then
        local Button = self:_requireCached("ui/widget/button")
        Button.new = self._original.Button_new
        self._original.Button_new = nil
    end
    
    if self._original.ButtonTable_new_global then
        local ButtonTable = self:_requireCached("ui/widget/buttontable")
        ButtonTable.new = self._original.ButtonTable_new_global
        self._original.ButtonTable_new_global = nil
    end
end

-- InfoMessage and ConfirmBox Hooks

function PocketBookTheme:_hookInfoMessageAndConfirmBox()
    local InfoMessage = self:_requireCached("ui/widget/infomessage")
    local ConfirmBox = self:_requireCached("ui/widget/confirmbox")
    local IconWidget = self:_requireCached("ui/widget/iconwidget")
    local TextBoxWidget = self:_requireCached("ui/widget/textboxwidget")
    local ButtonTable = self:_requireCached("ui/widget/buttontable")
    local VerticalSpan = self:_requireCached("ui/widget/verticalspan")
    local VerticalGroup = self:_requireCached("ui/widget/verticalgroup")
    local HorizontalSpan = self:_requireCached("ui/widget/horizontalspan")
    local HorizontalGroup = self:_requireCached("ui/widget/horizontalgroup")
    local Size = require("ui/size")
    
    if not self._original.InfoMessage_init then
        self._original.InfoMessage_init = InfoMessage.init
    end
    if not self._original.ConfirmBox_init then
        self._original.ConfirmBox_init = ConfirmBox.init
    end
    if not self._original.IconWidget_new then
        self._original.IconWidget_new = IconWidget.new
    end
    if not self._original.TextBoxWidget_new then
        self._original.TextBoxWidget_new = TextBoxWidget.new
    end
    if not self._original.ButtonTable_new_confirmbox then
        self._original.ButtonTable_new_confirmbox = ButtonTable.new
    end
    
    local theme = self
    local icon_size = self.ICON_SIZE
    local horizontal_padding = self.TEXT_PADDING_VERTICAL
    local span_width = Size.span.horizontal_default or 0
    
    -- Recalculate text width accounting for one horizontal padding at the end
    local calculated_text_width = self._cached_available_content_width - icon_size - span_width - horizontal_padding - 20
    
    local available_content_width = self._cached_available_content_width
    local custom_face = self._cached_custom_face
    
    InfoMessage.init = function(widget)
        if custom_face then
            widget.face = custom_face
        end
        
        -- Save current state
        local saved_IconWidget_new = IconWidget.new
        local saved_TextBoxWidget_new = TextBoxWidget.new
        
        IconWidget.new = function(class, o)
            o = o or {}
            if not o.width and not o.height then
                o.width = icon_size
                o.height = icon_size
                o.scale_factor = 0
            end
            return theme._original.IconWidget_new(class, o)
        end
        
        TextBoxWidget.new = function(class, o)
            o = o or {}
            
            if custom_face then
                o.face = custom_face
            end
            
            if o.width and o.width > calculated_text_width then
                o.width = calculated_text_width
            end
            return theme._original.TextBoxWidget_new(class, o)
        end
        
        theme._original.InfoMessage_init(widget)
        
        if widget.movable and widget.movable[1] and widget.movable[1][1] then
            local frame_container = widget.movable[1]
            local old_horizontal_group = frame_container[1]
            
            -- Create new HorizontalGroup with trailing padding span
            local new_horizontal_group = HorizontalGroup:new{
                align = old_horizontal_group.align or "center",
            }
            
            -- Copy all widgets from old group
            for i = 1, #old_horizontal_group do
                table.insert(new_horizontal_group, old_horizontal_group[i])
            end
            
            -- Add trailing span only
            table.insert(new_horizontal_group, HorizontalSpan:new{ width = horizontal_padding })
            
            local content_with_padding = VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
                new_horizontal_group,
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
            }
            
            frame_container[1] = content_with_padding
        end
        
        -- Restore previous state
        IconWidget.new = saved_IconWidget_new
        TextBoxWidget.new = saved_TextBoxWidget_new
    end
    
    ConfirmBox.init = function(widget)
        if custom_face then
            widget.face = custom_face
        end
        
        -- Save current state
        local saved_IconWidget_new = IconWidget.new
        local saved_TextBoxWidget_new = TextBoxWidget.new
        local saved_ButtonTable_new = ButtonTable.new
        
        IconWidget.new = function(class, o)
            o = o or {}
            if not o.width and not o.height then
                o.width = icon_size
                o.height = icon_size
                o.scale_factor = 0
            end
            return theme._original.IconWidget_new(class, o)
        end
        
        TextBoxWidget.new = function(class, o)
            o = o or {}
            
            if custom_face then
                o.face = custom_face
            end
            
            if o.width and o.width > calculated_text_width then
                o.width = calculated_text_width
            end
            return theme._original.TextBoxWidget_new(class, o)
        end
        
        ButtonTable.new = function(class, args)
            theme:_styleButtonsForWidget(args.buttons, "ConfirmBox")
            args.width = available_content_width
            
            return theme._original.ButtonTable_new_confirmbox(class, args)
        end
        
        theme._original.ConfirmBox_init(widget)
        
        if widget.movable and widget.movable[1] and widget.movable[1][1] then
            local frame_container = widget.movable[1]
            local vertical_group = frame_container[1]
            
            -- Get the horizontal_group (should be at position 1 after init)
            local old_horizontal_group = vertical_group[1]
            
            -- Replace with new HorizontalGroup with trailing padding only
            if old_horizontal_group and type(old_horizontal_group) == "table" then
                local new_horizontal_group = HorizontalGroup:new{
                    align = old_horizontal_group.align or "center",
                }
                
                -- Copy all widgets from old group
                for i = 1, #old_horizontal_group do
                    table.insert(new_horizontal_group, old_horizontal_group[i])
                end
                
                -- Add trailing span only
                table.insert(new_horizontal_group, HorizontalSpan:new{ width = horizontal_padding })
                
                vertical_group[1] = new_horizontal_group
            end
            
            -- Add vertical padding
            table.insert(vertical_group, 1, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            table.insert(vertical_group, 3, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            
            vertical_group:resetLayout()
        end
        
        -- Restore previous state
        IconWidget.new = saved_IconWidget_new
        TextBoxWidget.new = saved_TextBoxWidget_new
        ButtonTable.new = saved_ButtonTable_new
    end
    
    logger.info("PocketBookTheme: InfoMessage and ConfirmBox hooked with custom font face")
end

function PocketBookTheme:_unhookInfoMessageAndConfirmBox()
    if self._original.InfoMessage_init then
        local InfoMessage = self:_requireCached("ui/widget/infomessage")
        InfoMessage.init = self._original.InfoMessage_init
        self._original.InfoMessage_init = nil
    end
    
    if self._original.ConfirmBox_init then
        local ConfirmBox = self:_requireCached("ui/widget/confirmbox")
        ConfirmBox.init = self._original.ConfirmBox_init
        self._original.ConfirmBox_init = nil
    end
    
    if self._original.IconWidget_new then
        self._original.IconWidget_new = nil
    end
    if self._original.TextBoxWidget_new then
        self._original.TextBoxWidget_new = nil
    end
    if self._original.ButtonTable_new_confirmbox then
        self._original.ButtonTable_new_confirmbox = nil
    end
end

function PocketBookTheme:_hookUIManagerShow()
    local UIManager = self:_requireCached("ui/uimanager")
    
    if not self._original.UIManager_show then
        self._original.UIManager_show = UIManager.show
    end
    
    if not self._original.UIManager_close then
        self._original.UIManager_close = UIManager.close
    end
    
    local theme = self
    
    UIManager.show = function(self_ui, widget, ...)
        if widget and theme:_shouldApplyFrame(widget) then
            theme:_applyThemedFrame(widget)
        end
        
        return theme._original.UIManager_show(self_ui, widget, ...)
    end
    
    UIManager.close = function(self_ui, widget, ...)
        if widget and widget._pocketbook_themed then
            UIManager:setDirty("all", "flashui")
        end
        
        return theme._original.UIManager_close(self_ui, widget, ...)
    end
    
    logger.info("PocketBookTheme: UIManager:show and close hooked")
end

-- Frame Detection & Application

function PocketBookTheme:_shouldApplyFrame(widget)
    if not widget.movable or not widget.movable[1] or widget._pocketbook_themed then
        return false
    end
    
    -- Use weak table with direct reference
    if self._processed_widgets[widget] then
        return false
    end
    
    return widget.movable[1][1] ~= nil
end

function PocketBookTheme:_hasButtonTable(container)
    if not container then return false end
    
    if container.button_by_id then return true end
    
    if type(container) == "table" and #container > 0 then
        for _, child in ipairs(container) do
            if child.button_by_id then return true end
        end
    end
    return false
end

function PocketBookTheme:_applyThemedFrame(widget)
    local movable = widget.movable
    if not movable or not movable[1] then
        return false
    end
    
    local old_frame = movable[1]
    local content = old_frame[1]
    
    if not content then
        return false
    end
    
    widget._pocketbook_themed = true
    self._processed_widgets[widget] = true
    
    local original_padding = old_frame.padding or 0
    local original_background = old_frame.background or Blitbuffer.COLOR_WHITE
    
    local has_buttontable = self:_hasButtonTable(content)
    
    local new_padding_left = has_buttontable and 0 or (old_frame.padding_left or original_padding)
    local new_padding_right = has_buttontable and 0 or (old_frame.padding_right or original_padding)
    local new_padding_bottom = has_buttontable and 0 or (old_frame.padding_bottom or original_padding)
    
    local inner_frame = FrameContainer:new{
        radius = self._cached_inner_radius,
        bordersize = 1,
        color = Blitbuffer.COLOR_BLACK,
        background = original_background,
        padding = 0,
        padding_top = old_frame.padding_top or original_padding,
        padding_bottom = new_padding_bottom,
        padding_left = new_padding_left,
        padding_right = new_padding_right,
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
    
    movable[1] = outer_frame
    
    if self:_shouldPositionAtBottom(widget) then
        self:_positionAtBottom(widget)
    end
    
    return true
end

-- Bottom Positioning

function PocketBookTheme:_shouldPositionAtBottom(widget)
    -- Combined conditions for efficiency
    return (widget.text and widget.face and not widget.buttons) or
           widget.__class__ == "ConfirmBox" or
           (widget.text and widget.face and widget.buttons and (widget.ok_text or widget.cancel_text))
end

function PocketBookTheme:_positionAtBottom(widget)
    if not widget[1] then
        return
    end
    
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

-- Button Styling

function PocketBookTheme:_styleButtonsForWidget(buttons, widget_type)
    if not buttons then
        return
    end
    
    local Utf8Proc = require("ffi/utf8proc")
    local button_height = self.BUTTON_HEIGHT
    local apply_uppercase = (widget_type ~= "ButtonDialog")
    
    for _, row in ipairs(buttons) do
        for _, btn in ipairs(row) do
            if btn.text and apply_uppercase then
                btn.text = Utf8Proc.uppercase_dumb(btn.text)
            end
            
            btn.height = button_height
            btn.font_bold = false
        end
    end
end

return PocketBookTheme