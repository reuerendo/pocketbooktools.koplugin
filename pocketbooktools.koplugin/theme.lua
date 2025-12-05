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
    
    -- Font settings - will be resolved on init
    FONT_REGULAR = nil,
    FONT_BOLD = nil,
    
    -- Possible font locations
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

-- ============================================================================
-- Initialization & State Management
-- ============================================================================

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

-- ============================================================================
-- Font Path Resolution
-- ============================================================================

function PocketBookTheme:_resolveFontPaths()
    local roboto_regular = "Roboto-Regular.ttf"
    local roboto_bold = "Roboto-Bold.ttf"
    
    -- Try system fonts first (PocketBook default location)
    local system_regular = self.FONT_PATHS.system .. "/" .. roboto_regular
    local system_bold = self.FONT_PATHS.system .. "/" .. roboto_bold
    
    if self:_fileExists(system_regular) and self:_fileExists(system_bold) then
        self.FONT_REGULAR = system_regular
        self.FONT_BOLD = system_bold
        logger.info("PocketBookTheme: Using system fonts from /system/fonts")
        return true
    end
    
    -- Try KOReader fonts folder
    local koreader_regular = self.FONT_PATHS.koreader .. "/" .. roboto_regular
    local koreader_bold = self.FONT_PATHS.koreader .. "/" .. roboto_bold
    
    if self:_fileExists(koreader_regular) and self:_fileExists(koreader_bold) then
        self.FONT_REGULAR = koreader_regular
        self.FONT_BOLD = koreader_bold
        logger.info("PocketBookTheme: Using fonts from KOReader fonts folder")
        return true
    end
    
    -- Try creating symlinks if system fonts exist
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
    -- Ensure KOReader fonts directory exists
    local fonts_dir = self.FONT_PATHS.koreader
    local mode = lfs.attributes(fonts_dir, "mode")
    if mode ~= "directory" then
        logger.warn("PocketBookTheme: fonts directory does not exist:", fonts_dir)
        return false
    end
    
    -- Try to create symlinks using os.execute
    local success = true
    
    -- Create symlink for regular font
    if not self:_fileExists(dst_regular) then
        local cmd = string.format('ln -s "%s" "%s"', src_regular, dst_regular)
        local result = os.execute(cmd)
        if result ~= 0 then
            logger.warn("PocketBookTheme: Failed to create symlink for regular font")
            success = false
        else
            logger.dbg("PocketBookTheme: Created symlink:", dst_regular)
        end
    end
    
    -- Create symlink for bold font
    if not self:_fileExists(dst_bold) then
        local cmd = string.format('ln -s "%s" "%s"', src_bold, dst_bold)
        local result = os.execute(cmd)
        if result ~= 0 then
            logger.warn("PocketBookTheme: Failed to create symlink for bold font")
            success = false
        else
            logger.dbg("PocketBookTheme: Created symlink:", dst_bold)
        end
    end
    
    return success
end

-- ============================================================================
-- Theme Application
-- ============================================================================

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
    -- Restore fonts
    self:_restoreFonts()
    
    -- Restore InfoMessage and ConfirmBox
    self:_unhookInfoMessageAndConfirmBox()
    
    -- Restore ButtonTable
    self:_unhookButtonTable()
    
    -- Restore widget class constructors
    for class_name, original_new in pairs(self._hooked_classes) do
        local success, widget_class = pcall(require, class_name)
        if success and widget_class then
            widget_class.new = original_new
            logger.dbg("PocketBookTheme: Restored", class_name)
        end
    end
    self._hooked_classes = {}
    
    -- Restore UIManager:show
    if self._original.UIManager_show then
        local UIManager = require("ui/uimanager")
        UIManager.show = self._original.UIManager_show
        self._original.UIManager_show = nil
    end
    
    self._processed_widgets = {}
    logger.info("PocketBookTheme: Theme restored")
end

-- ============================================================================
-- Font Management
-- ============================================================================

function PocketBookTheme:_applyFontChanges()
    local Font = require("ui/font")
    
    if not Font.fontmap then
        logger.warn("PocketBookTheme: Font.fontmap not available")
        return false
    end
    
    -- Save original fontmap if not already saved
    if not next(self._original_fontmap) then
        for key, value in pairs(Font.fontmap) do
            self._original_fontmap[key] = value
        end
        logger.dbg("PocketBookTheme: Saved original fontmap")
    end
    
    -- List of font keys to replace (exclude monospace)
    local font_keys_to_replace = {
        "cfont",        -- menu & UI elements
        "tfont",        -- titles
        "ffont",        -- footer
        "smallfont",    -- small text
        "x_smallfont",  -- extra small text
        "infofont",     -- info text (used by ConfirmBox & InfoMessage)
        "smallinfofont",-- small info text
        "largefont",    -- large text
        "smalltfont",   -- small title
        "x_smalltfont", -- extra small title
        "smallffont",   -- small footer
        "largeffont",   -- large footer
        "rifont",       -- reading position info
    }
    
    local changed_count = 0
    
    for _, key in ipairs(font_keys_to_replace) do
        if Font.fontmap[key] then
            local original = Font.fontmap[key]
            
            -- Check if this is not a monospace font
            if not (original:find("Mono") or original:find("mono") or 
                    original:find("Code") or original:find("Courier") or
                    original:find("Droid") and original:find("Sans") and original:find("Mono")) then
                
                -- Determine if bold or regular
                local is_bold = original:find("Bold") or original:find("bold")
                local new_font = is_bold and self.FONT_BOLD or self.FONT_REGULAR
                
                Font.fontmap[key] = new_font
                changed_count = changed_count + 1
                logger.dbg(string.format("PocketBookTheme: Changed %s: %s -> %s", 
                                        key, original, new_font))
            else
                logger.dbg(string.format("PocketBookTheme: Skipped monospace font %s: %s", 
                                        key, original))
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
        logger.dbg("PocketBookTheme: No original fontmap to restore")
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
            logger.dbg(string.format("PocketBookTheme: Restored %s to %s", key, original_value))
        end
    end
    
    self._original_fontmap = {}
    logger.info(string.format("PocketBookTheme: Restored %d fonts to original", restored_count))
end

-- ============================================================================
-- Widget Class Hooks
-- ============================================================================

function PocketBookTheme:_hookWidgetClasses()
    -- List of widget classes that need width constraint
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
            -- Save original constructor
            if not self._hooked_classes[class_path] then
                self._hooked_classes[class_path] = widget_class.new
                
                -- Hook constructor
                widget_class.new = function(class, args)
                    -- Calculate available width for content (excluding borders and padding)
                    local content_width = max_content_width - (theme.BORDER_SIZE * 2) - 2
                    
                    -- Set or constrain width parameter
                    if not args.width or args.width > content_width then
                        args.width = content_width
                        logger.dbg("PocketBookTheme: Set width for", class_path, "to", content_width)
                    end
                    
                    -- Style buttons for ButtonDialog (without uppercase)
                    if class_path == "ui/widget/buttondialog" and args.buttons then
                        theme:_styleButtonsForWidget(args.buttons, "ButtonDialog")
                    end
                    
                    -- Call original constructor with modified args
                    return theme._hooked_classes[class_path](class, args)
                end
                
                logger.dbg("PocketBookTheme: Hooked", class_path)
            end
        else
            logger.dbg("PocketBookTheme: Could not hook", class_path)
        end
    end
end

-- ============================================================================
-- ButtonTable Hook
-- ============================================================================

function PocketBookTheme:_hookButtonTable()
    local Button = require("ui/widget/button")
    
    -- Save original Button.new
    if not self._original.Button_new then
        self._original.Button_new = Button.new
    end
    
    local theme = self
    
    -- Hook Button.new to modify button properties when created by ButtonTable
    Button.new = function(class, args)
        -- Check if this button is being created by ButtonTable
        -- ButtonTable sets specific properties like bordersize = 0, margin = 0
        if args.bordersize == 0 and args.margin == 0 then
            -- Remove radius to eliminate rounded corners
            args.radius = 0
            
            -- Ensure padding is set to 0 (ButtonTable uses padding from Size.padding.buttontable)
            -- We override this to have no padding around buttons
            args.padding = 0
            args.padding_h = 0
            args.padding_v = 0
            
            logger.dbg("PocketBookTheme: Modified Button - removed radius and padding")
        end
        
        -- Call original constructor
        return theme._original.Button_new(class, args)
    end
    
    logger.info("PocketBookTheme: ButtonTable button styling hooked")
end

function PocketBookTheme:_unhookButtonTable()
    if self._original.Button_new then
        local Button = require("ui/widget/button")
        Button.new = self._original.Button_new
        self._original.Button_new = nil
        logger.dbg("PocketBookTheme: Restored Button.new")
    end
end

-- ============================================================================
-- InfoMessage and ConfirmBox Hooks
-- ============================================================================

function PocketBookTheme:_hookInfoMessageAndConfirmBox()
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local IconWidget = require("ui/widget/iconwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local ButtonTable = require("ui/widget/buttontable")
    local VerticalSpan = require("ui/widget/verticalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    
    -- Save originals
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
    
    -- Create custom font face with Roboto at size 18
    local custom_face = nil
    if self.FONT_REGULAR then
        custom_face = Font:getFace(self.FONT_REGULAR, self.FONT_SIZE)
        logger.dbg("PocketBookTheme: Created custom face with Roboto at size", self.FONT_SIZE)
    end
    
    -- Hook InfoMessage init
    InfoMessage.init = function(widget)
        -- Override face if we have custom font
        if custom_face then
            widget.face = custom_face
            logger.dbg("PocketBookTheme: Set custom face for InfoMessage")
        end
        
        -- Temporarily override IconWidget.new
        IconWidget.new = function(class, o)
            o = o or {}
            if not o.width and not o.height then
                o.width = icon_size
                o.height = icon_size
                o.scale_factor = 0
                logger.dbg("PocketBookTheme: Set IconWidget size to", icon_size, "for InfoMessage")
            end
            return theme._original.IconWidget_new(class, o)
        end
        
        -- Temporarily override TextBoxWidget.new
        TextBoxWidget.new = function(class, o)
            o = o or {}
            
            -- Apply custom face if available
            if custom_face then
                o.face = custom_face
            end
            
            if o.width and o.width > calculated_text_width then
                logger.dbg("PocketBookTheme: Limiting TextBoxWidget width from", o.width, "to", calculated_text_width, "for InfoMessage")
                o.width = calculated_text_width
            end
            return theme._original.TextBoxWidget_new(class, o)
        end
        
        -- Call original init
        theme._original.InfoMessage_init(widget)
        
        -- Add vertical padding to the content
        -- Structure for InfoMessage: widget.movable[1] is FrameContainer containing HorizontalGroup
        if widget.movable and widget.movable[1] and widget.movable[1][1] then
            local frame_container = widget.movable[1]
            local horizontal_group = frame_container[1]
            
            -- Wrap HorizontalGroup in VerticalGroup with padding
            local content_with_padding = VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
                horizontal_group,
                VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL },
            }
            
            -- Replace content in frame
            frame_container[1] = content_with_padding
            
            logger.dbg("PocketBookTheme: Added vertical padding to InfoMessage content")
        end
        
        -- Restore IconWidget and TextBoxWidget
        IconWidget.new = theme._original.IconWidget_new
        TextBoxWidget.new = theme._original.TextBoxWidget_new
    end
    
    -- Hook ConfirmBox init
    ConfirmBox.init = function(widget)
        -- Override face if we have custom font
        if custom_face then
            widget.face = custom_face
            logger.dbg("PocketBookTheme: Set custom face for ConfirmBox")
        end
        
        -- Temporarily override IconWidget.new
        IconWidget.new = function(class, o)
            o = o or {}
            if not o.width and not o.height then
                o.width = icon_size
                o.height = icon_size
                o.scale_factor = 0
                logger.dbg("PocketBookTheme: Set IconWidget size to", icon_size, "for ConfirmBox")
            end
            return theme._original.IconWidget_new(class, o)
        end
        
        -- Temporarily override TextBoxWidget.new
        TextBoxWidget.new = function(class, o)
            o = o or {}
            
            -- Apply custom face if available
            if custom_face then
                o.face = custom_face
            end
            
            if o.width and o.width > calculated_text_width then
                logger.dbg("PocketBookTheme: Limiting TextBoxWidget width from", o.width, "to", calculated_text_width, "for ConfirmBox")
                o.width = calculated_text_width
            end
            return theme._original.TextBoxWidget_new(class, o)
        end
        
        -- Temporarily override ButtonTable.new to style buttons
        ButtonTable.new = function(class, args)
            -- Style buttons before creating ButtonTable
            theme:_styleButtonsForWidget(args.buttons, "ConfirmBox")
            return theme._original.ButtonTable_new(class, args)
        end
        
        -- Call original init
        theme._original.ConfirmBox_init(widget)
        
        -- Add vertical padding to the content group (icon + text)
        -- Structure: widget.movable[1][1] is VerticalGroup containing content and buttons
        if widget.movable and widget.movable[1] and widget.movable[1][1] then
            local vertical_group = widget.movable[1][1]
            -- Insert padding at the beginning (before content)
            table.insert(vertical_group, 1, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            -- Insert padding after content but before the vertical span and button table
            -- Content is at position 2 (after our first padding), next element should be at 3
            table.insert(vertical_group, 2 + 1, VerticalSpan:new{ width = theme.TEXT_PADDING_VERTICAL })
            vertical_group:resetLayout()
            logger.dbg("PocketBookTheme: Added vertical padding to ConfirmBox content")
        end
        
        -- Restore IconWidget, TextBoxWidget and ButtonTable
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
        logger.dbg("PocketBookTheme: Restored InfoMessage.init")
    end
    
    if self._original.ConfirmBox_init then
        local ConfirmBox = require("ui/widget/confirmbox")
        ConfirmBox.init = self._original.ConfirmBox_init
        self._original.ConfirmBox_init = nil
        logger.dbg("PocketBookTheme: Restored ConfirmBox.init")
    end
    
    -- Overrides are restored inside init hooks
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
        -- Apply themed frame to dialogs with MovableContainer
        if widget and theme:_shouldApplyFrame(widget) then
            local success = theme:_applyThemedFrame(widget)
            
            if success then
                logger.dbg("PocketBookTheme: Applied frame to widget:", widget.name or "unnamed")
            end
        end
        
        return theme._original.UIManager_show(self_ui, widget, ...)
    end
    
    logger.info("PocketBookTheme: UIManager:show hooked")
end

-- ============================================================================
-- Frame Detection & Application
-- ============================================================================

function PocketBookTheme:_shouldApplyFrame(widget)
    if not widget.movable then
        return false
    end
    
    if not widget.movable[1] then
        return false
    end
    
    if widget._pocketbook_themed then
        return false
    end
    
    local widget_id = tostring(widget)
    if self._processed_widgets[widget_id] then
        return false
    end
    
    local frame = widget.movable[1]
    if not frame[1] then
        return false
    end
    
    return true
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
    
    -- Mark as processed
    widget._pocketbook_themed = true
    local widget_id = tostring(widget)
    self._processed_widgets[widget_id] = true
    
    -- Get original frame properties
    local original_padding = old_frame.padding or 0
    local original_padding_top = old_frame.padding_top or original_padding
    local original_padding_bottom = old_frame.padding_bottom or original_padding
    local original_padding_left = old_frame.padding_left or original_padding
    local original_padding_right = old_frame.padding_right or original_padding
    local original_background = old_frame.background or Blitbuffer.COLOR_WHITE
    
    -- Create inner frame
    local inner_radius = math.max(0, self.RADIUS - self.BORDER_SIZE)
    local inner_frame = FrameContainer:new{
        radius = inner_radius,
        bordersize = 1,
        color = Blitbuffer.COLOR_BLACK,
        background = original_background,
        padding = 0,
        padding_top = original_padding_top,
        padding_bottom = original_padding_bottom,
        padding_left = original_padding_left,
        padding_right = original_padding_right,
        content
    }
    
    -- Create outer frame
    local outer_frame = FrameContainer:new{
        radius = self.RADIUS,
        bordersize = self.BORDER_SIZE,
        color = Blitbuffer.COLOR_BLACK,
        background = Blitbuffer.COLOR_BLACK,
        padding = 0,
        inner_frame,
    }
    
    movable[1] = outer_frame
    
    -- Check if this widget should be positioned at bottom
    if self:_shouldPositionAtBottom(widget) then
        self:_positionAtBottom(widget)
        logger.dbg("PocketBookTheme: Positioned widget at bottom")
    end
    
    logger.dbg("PocketBookTheme: Applied themed frame")
    
    return true
end

-- ============================================================================
-- Bottom Positioning
-- ============================================================================

function PocketBookTheme:_shouldPositionAtBottom(widget)
    -- Check widget type by examining its properties
    -- InfoMessage and ConfirmBox should be positioned at bottom
    
    -- InfoMessage detection
    if widget.text and widget.face and not widget.buttons then
        return true
    end
    
    -- ConfirmBox detection
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
    
    logger.dbg("PocketBookTheme: Applied bottom positioning with margin:", bottom_margin)
end

-- ============================================================================
-- Button Styling
-- ============================================================================

function PocketBookTheme:_styleButtonsForWidget(buttons, widget_type)
    if not buttons then
        return
    end
    
    local Utf8Proc = require("ffi/utf8proc")
    local button_height = Screen:scaleBySize(60)
    
    -- Determine if we should apply uppercase (not for ButtonDialog)
    local apply_uppercase = (widget_type ~= "ButtonDialog")
    
    for _, row in ipairs(buttons) do
        for _, btn in ipairs(row) do
            -- Apply uppercase transformation for all widgets except ButtonDialog
            if btn.text and apply_uppercase then
                btn.text = Utf8Proc.uppercase_dumb(btn.text)
                logger.dbg("PocketBookTheme: Uppercased button text for", widget_type)
            end
            
            -- Set button height
            if not btn.height then
                btn.height = button_height
            end
            
            -- Ensure font is NOT bold
            btn.font_bold = false
            
            logger.dbg("PocketBookTheme: Styled button for", widget_type, "- height:", btn.height, "bold:", btn.font_bold)
        end
    end
end

return PocketBookTheme