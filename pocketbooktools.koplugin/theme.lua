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
    
    _original = {},
    _enabled = false,
    _processed_widgets = {},
    _hooked_classes = {},
    _original_fontmap = {},
}

-- Initialization & State Management

function PocketBookTheme:init()
    self:_resolveFontPaths()
    self._enabled = G_reader_settings:isTrue("pocketbook_theme_enabled")
    
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

-- Font Path Resolution

function PocketBookTheme:_resolveFontPaths()
    local roboto_regular = "Roboto-Regular.ttf"
    local roboto_bold = "Roboto-Bold.ttf"
    
    local system_regular = self.FONT_PATHS.system .. "/" .. roboto_regular
    local system_bold = self.FONT_PATHS.system .. "/" .. roboto_bold
    
    if self:_fileExists(system_regular) and self:_fileExists(system_bold) then
        self.FONT_REGULAR = system_regular
        self.FONT_BOLD = system_bold
        logger.info("PocketBookTheme: Using system fonts from /system/fonts")
        return true
    end
    
    local koreader_regular = self.FONT_PATHS.koreader .. "/" .. roboto_regular
    local koreader_bold = self.FONT_PATHS.koreader .. "/" .. roboto_bold
    
    if self:_fileExists(koreader_regular) and self:_fileExists(koreader_bold) then
        self.FONT_REGULAR = koreader_regular
        self.FONT_BOLD = koreader_bold
        logger.info("PocketBookTheme: Using fonts from KOReader fonts folder")
        return true
    end
    
    if self:_fileExists(system_regular) and self:_fileExists(system_bold) then
        if self:_createSymlinks(system_regular, system_bold, koreader_regular, koreader_bold) then
            self.FONT_REGULAR = koreader_regular
            self.FONT_BOLD = koreader_bold
            logger.info("PocketBookTheme: Created symlinks to system fonts")
            return true
        end
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
        local success, widget_class = pcall(require, class_name)
        if success and widget_class then
            widget_class.new = original_new
        end
    end
    self._hooked_classes = {}
    
    if self._original.UIManager_show then
        local UIManager = require("ui/uimanager")
        UIManager.show = self._original.UIManager_show
        self._original.UIManager_show = nil
    end
    
    if self._original.DictQuickLookup_new then
        local DictQuickLookup = require("ui/widget/dictquicklookup")
        DictQuickLookup.new = self._original.DictQuickLookup_new
        self._original.DictQuickLookup_new = nil
    end
    
    self._processed_widgets = {}
    logger.info("PocketBookTheme: Theme restored")
end

-- Font Management

function PocketBookTheme:_applyFontChanges()
    local Font = require("ui/font")
    
    if not Font.fontmap then
        logger.warn("PocketBookTheme: Font.fontmap not available")
        return false
    end
    
    if not next(self._original_fontmap) then
        for key, value in pairs(Font.fontmap) do
            self._original_fontmap[key] = value
        end
    end
    
    local font_keys_to_replace = {
        "cfont", "tfont", "ffont", "smallfont", "x_smallfont", "infofont",
        "smallinfofont", "largefont", "smalltfont", "x_smalltfont",
        "smallffont", "largeffont", "rifont",
    }
    
    local changed_count = 0
    
    for _, key in ipairs(font_keys_to_replace) do
        if Font.fontmap[key] then
            local original = Font.fontmap[key]
            
            if not (original:find("Mono") or original:find("mono") or 
                    original:find("Code") or original:find("Courier") or
                    original:find("Droid") and original:find("Sans") and original:find("Mono")) then
                
                local is_bold = original:find("Bold") or original:find("bold")
                Font.fontmap[key] = is_bold and self.FONT_BOLD or self.FONT_REGULAR
                changed_count = changed_count + 1
            end
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
    
    local Font = require("ui/font")
    
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
    
    local screen_width = Screen:getSize().w
    local max_content_width = math.floor(screen_width * self.MAX_WIDTH_PERCENT)
    local theme = self
    
    for _, class_path in ipairs(widget_classes) do
        local success, widget_class = pcall(require, class_path)
        if success and widget_class and widget_class.new then
            if not self._hooked_classes[class_path] then
                self._hooked_classes[class_path] = widget_class.new
                
                widget_class.new = function(class, args)
                    local content_width = max_content_width - (theme.BORDER_SIZE * 2) - 2
                    
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
        self._original.DictQuickLookup_new = DictQuickLookup.new
    end
    
    local screen_width = Screen:getSize().w
    local max_width = math.floor(screen_width * self.MAX_WIDTH_PERCENT)
    local theme = self
    
    DictQuickLookup.new = function(class, args)
        local frame_overhead = (theme.BORDER_SIZE * 2) + 2
        args.width = max_width - frame_overhead
        
        return theme._original.DictQuickLookup_new(class, args)
    end
    
    logger.info("PocketBookTheme: Hooked DictQuickLookup")
end

-- ButtonTable Hook

function PocketBookTheme:_hookButtonTable()
    local Button = require("ui/widget/button")
    local ButtonTable = require("ui/widget/buttontable")
    local Utf8Proc = require("ffi/utf8proc")
    
    if not self._original.Button_new then
        self._original.Button_new = Button.new
    end
    
    if not self._original.ButtonTable_new_global then
        self._original.ButtonTable_new_global = ButtonTable.new
    end
    
    local theme = self
    local button_height = self.BUTTON_HEIGHT
    
    local current_buttontable_context = nil
    
    ButtonTable.new = function(class, args)
        local is_buttondialog = false
        
        local traceback = debug.traceback()
        if traceback:find("buttondialog") then
            is_buttondialog = true
        end
        
        if args.buttons and not is_buttondialog then
            for _, row in ipairs(args.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text then
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
        local Button = require("ui/widget/button")
        Button.new = self._original.Button_new
        self._original.Button_new = nil
    end
    
    if self._original.ButtonTable_new_global then
        local ButtonTable = require("ui/widget/buttontable")
        ButtonTable.new = self._original.ButtonTable_new_global
        self._original.ButtonTable_new_global = nil
    end
end

-- InfoMessage and ConfirmBox Hooks

function PocketBookTheme:_hookInfoMessageAndConfirmBox()
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local IconWidget = require("ui/widget/iconwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local ButtonTable = require("ui/widget/buttontable")
    local VerticalSpan = require("ui/widget/verticalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    
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
    if not self._original.ButtonTable_new then
        self._original.ButtonTable_new = ButtonTable.new
    end
    
    local theme = self
    local icon_size = self.ICON_SIZE
    local screen_width = Screen:getSize().w
    local max_width = math.floor(screen_width * self.MAX_WIDTH_PERCENT)
    local frame_padding = (self.BORDER_SIZE * 2) + 2
    local available_content_width = max_width - frame_padding
    local span_width = Size.span.horizontal_default or 0
    local calculated_text_width = available_content_width - icon_size - span_width - 20
    
    local custom_face = nil
    if self.FONT_REGULAR then
        custom_face = Font:getFace(self.FONT_REGULAR, self.FONT_SIZE)
    end
    
    InfoMessage.init = function(widget)
        if custom_face then
            widget.face = custom_face
        end
        
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
            local horizontal_group = frame_container[1]
            
            local content_with_padding = VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
                horizontal_group,
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
            }
            
            frame_container[1] = content_with_padding
        end
        
        IconWidget.new = theme._original.IconWidget_new
        TextBoxWidget.new = theme._original.TextBoxWidget_new
    end
    
    ConfirmBox.init = function(widget)
        if custom_face then
            widget.face = custom_face
        end
        
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
            
            return theme._original.ButtonTable_new(class, args)
        end
        
        theme._original.ConfirmBox_init(widget)
        
        if widget.movable and widget.movable[1] and widget.movable[1][1] then
            local vertical_group = widget.movable[1][1]
            table.insert(vertical_group, 1, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            table.insert(vertical_group, 3, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            vertical_group:resetLayout()
        end
        
        IconWidget.new = theme._original.IconWidget_new
        TextBoxWidget.new = theme._original.TextBoxWidget_new
        ButtonTable.new = theme._original.ButtonTable_new
    end
    
    logger.info("PocketBookTheme: InfoMessage and ConfirmBox hooked with custom font face")
end

function PocketBookTheme:_unhookInfoMessageAndConfirmBox()
    if self._original.InfoMessage_init then
        local InfoMessage = require("ui/widget/infomessage")
        InfoMessage.init = self._original.InfoMessage_init
        self._original.InfoMessage_init = nil
    end
    
    if self._original.ConfirmBox_init then
        local ConfirmBox = require("ui/widget/confirmbox")
        ConfirmBox.init = self._original.ConfirmBox_init
        self._original.ConfirmBox_init = nil
    end
    
    if self._original.IconWidget_new then
        self._original.IconWidget_new = nil
    end
    if self._original.TextBoxWidget_new then
        self._original.TextBoxWidget_new = nil
    end
    if self._original.ButtonTable_new then
        self._original.ButtonTable_new = nil
    end
end

function PocketBookTheme:_hookUIManagerShow()
    local UIManager = require("ui/uimanager")
    
    if not self._original.UIManager_show then
        self._original.UIManager_show = UIManager.show
    end
    
    local theme = self
    
    UIManager.show = function(self_ui, widget, ...)
        if widget and theme:_shouldApplyFrame(widget) then
            theme:_applyThemedFrame(widget)
        end
        
        return theme._original.UIManager_show(self_ui, widget, ...)
    end
    
    logger.info("PocketBookTheme: UIManager:show hooked")
end

-- Frame Detection & Application

function PocketBookTheme:_shouldApplyFrame(widget)
    if not widget.movable or not widget.movable[1] or widget._pocketbook_themed then
        return false
    end
    
    local widget_id = tostring(widget)
    if self._processed_widgets[widget_id] then
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
    self._processed_widgets[tostring(widget)] = true
    
    local original_padding = old_frame.padding or 0
    local original_background = old_frame.background or Blitbuffer.COLOR_WHITE
    
    local has_buttontable = self:_hasButtonTable(content)
    
    local new_padding_left = has_buttontable and 0 or (old_frame.padding_left or original_padding)
    local new_padding_right = has_buttontable and 0 or (old_frame.padding_right or original_padding)
    local new_padding_bottom = has_buttontable and 0 or (old_frame.padding_bottom or original_padding)
    
    local inner_radius = math.max(0, self.RADIUS - self.BORDER_SIZE)
    local inner_frame = FrameContainer:new{
        radius = inner_radius,
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
    if widget.text and widget.face and not widget.buttons then
        return true
    end
    
    if widget.ok_text or widget.cancel_text or widget.ok_callback then
        return true
    end
    
    return false
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