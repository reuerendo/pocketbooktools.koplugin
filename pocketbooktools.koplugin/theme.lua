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
    WIKIPEDIA_WIDTH_PERCENT = 0.9,
    WIKIPEDIA_HEIGHT_PERCENT = 0.9,
    
    FONT_REGULAR = nil,
    FONT_BOLD = nil,
    
    FONT_PATHS = {
        system = "/system/fonts",
        koreader = "fonts",
    },
    
    FONT_KEYS_TO_REPLACE = {
        "cfont", "tfont", "ffont", "smallffont", "largeffont",
        "pgfont", "rifont", "hfont", "infofont",
        "smallinfofont", "x_smallinfofont", "xx_smallinfofont",
        "smalltfont", "x_smalltfont", "smallinfofontbold",
    },
    
    -- Widget classes that should be themed (consolidated list)
	WIDGET_CLASSES = {
		"ui/widget/infomessage",
		"ui/widget/confirmbox",
		"ui/widget/multiconfirmbox",
		"ui/widget/buttondialog",
		"ui/widget/inputdialog",
		"ui/widget/multiinputdialog",
		"ui/widget/dictquicklookup",
		"ui/widget/spinwidget",
		"ui/widget/textviewer",
		"ui/widget/frontlightwidget",
		"plugins/summary.koplugin/summary", -- Add custom plugin widget
	},
    
    _original = {},
    _enabled = false,
    _processed_widgets = nil,
    _hooked_classes = {},
    _original_fontmap = {},
    _cached_modules = {},
    _widget_types = nil,
    
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
    self._processed_widgets = setmetatable({}, {__mode = "k"})
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
    local roboto_files = {
        regular = "Roboto-Regular.ttf",
        bold = "Roboto-Bold.ttf"
    }
    
    local paths = {
        system = self.FONT_PATHS.system,
        koreader = self.FONT_PATHS.koreader
    }
    
    -- Check KOReader fonts first
    local kr_regular = paths.koreader .. "/" .. roboto_files.regular
    local kr_bold = paths.koreader .. "/" .. roboto_files.bold
    
    if self:_fileExists(kr_regular) and self:_fileExists(kr_bold) then
        self.FONT_REGULAR = kr_regular
        self.FONT_BOLD = kr_bold
        logger.info("PocketBookTheme: Using fonts from KOReader fonts folder")
        return true
    end
    
    -- Check system fonts
    local sys_regular = paths.system .. "/" .. roboto_files.regular
    local sys_bold = paths.system .. "/" .. roboto_files.bold
    
    if self:_fileExists(sys_regular) and self:_fileExists(sys_bold) then
        -- Try to create symlinks
        if self:_createSymlinks(sys_regular, sys_bold, kr_regular, kr_bold) then
            self.FONT_REGULAR = kr_regular
            self.FONT_BOLD = kr_bold
            logger.info("PocketBookTheme: Created symlinks to system fonts")
        else
            self.FONT_REGULAR = sys_regular
            self.FONT_BOLD = sys_bold
            logger.info("PocketBookTheme: Using system fonts from /system/fonts")
        end
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
    if lfs.attributes(self.FONT_PATHS.koreader, "mode") ~= "directory" then
        logger.warn("PocketBookTheme: fonts directory does not exist:", self.FONT_PATHS.koreader)
        return false
    end
    
    local links = {
        {src = src_regular, dst = dst_regular, name = "regular"},
        {src = src_bold, dst = dst_bold, name = "bold"}
    }
    
    for _, link in ipairs(links) do
        if not self:_fileExists(link.dst) then
            if os.execute(string.format('ln -s "%s" "%s"', link.src, link.dst)) ~= 0 then
                logger.warn("PocketBookTheme: Failed to create symlink for " .. link.name .. " font")
                return false
            end
        end
    end
    
    return true
end

-- Theme Application
function PocketBookTheme:_applyTheme()
    if self.FONT_REGULAR and self.FONT_BOLD then
        self:_applyFontChanges()
    end
    self:_hookWidgetClasses()
	self:_hookFrontLightWidget()
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
    
    -- Restore UIManager.show
    if self._original.UIManager_show then
        local UIManager = self:_requireCached("ui/uimanager")
        UIManager.show = self._original.UIManager_show
        self._original.UIManager_show = nil
    end
    
    -- Restore DictQuickLookup
    if self._original.DictQuickLookup_new then
        local DictQuickLookup = self:_requireCached("ui/widget/dictquicklookup")
        DictQuickLookup.new = self._original.DictQuickLookup_new
        self._original.DictQuickLookup_new = nil
    end
    if self._original.DictQuickLookup_init then
        local DictQuickLookup = self:_requireCached("ui/widget/dictquicklookup")
        DictQuickLookup.init = self._original.DictQuickLookup_init
        self._original.DictQuickLookup_init = nil
    end
	
    if self._original.FrontLightWidget_init then
        local FrontLightWidget = self:_requireCached("ui/widget/frontlightwidget")
        FrontLightWidget.init = self._original.FrontLightWidget_init
        self._original.FrontLightWidget_init = nil
    end
    
    self._processed_widgets = setmetatable({}, {__mode = "k"})
    logger.info("PocketBookTheme: Theme restored")
end

-- Font Management
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
    
    local fontmap_overrides = {}
    
    for _, key in ipairs(self.FONT_KEYS_TO_REPLACE) do
        local original = Font.fontmap[key]
        if original then
            local font = original:find("[Bb]old") and self.FONT_BOLD or self.FONT_REGULAR
            Font.fontmap[key] = font
            fontmap_overrides[key] = font
        end
    end
    
    if next(fontmap_overrides) then
        G_reader_settings:saveSetting("fontmap", fontmap_overrides)
        G_reader_settings:flush()
        logger.info(string.format("PocketBookTheme: Changed %d UI fonts to Roboto and saved to settings", 
                                   #self.FONT_KEYS_TO_REPLACE))
        return true
    end
    
    logger.warn("PocketBookTheme: No fonts were changed")
    return false
end

function PocketBookTheme:_restoreFonts()
    if not next(self._original_fontmap) then
        return
    end
    
    local Font = self:_requireCached("ui/font")
    
    if Font.fontmap then
        for key, original_value in pairs(self._original_fontmap) do
            if Font.fontmap[key] then
                Font.fontmap[key] = original_value
            end
        end
    end
    
    G_reader_settings:delSetting("fontmap")
    G_reader_settings:flush()
    
    self._original_fontmap = {}
    logger.info("PocketBookTheme: Restored fonts to original and removed from settings")
end

-- Widget Class Hooks
function PocketBookTheme:_hookWidgetClasses()
    local widget_classes = {
        "ui/widget/buttondialog",
        "ui/widget/inputdialog",
        "ui/widget/multiinputdialog",
        "ui/widget/frontlightwidget",
    }
    
    local max_content_width = self._cached_max_content_width
    local border_size = self.BORDER_SIZE
    local theme = self
    
    for _, class_path in ipairs(widget_classes) do
        local success, widget_class = pcall(require, class_path)
        if success and widget_class and widget_class.new and not self._hooked_classes[class_path] then
            self._cached_modules[class_path] = widget_class
            self._hooked_classes[class_path] = widget_class.new
            
            widget_class.new = function(class, args)
                args = args or {}
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
    
    self:_hookDictQuickLookup()
end

function PocketBookTheme:_hookFrontLightWidget()
    local success, FrontLightWidget = pcall(require, "ui/widget/frontlightwidget")
    if not success or not FrontLightWidget then
        logger.warn("PocketBookTheme: Could not load FrontLightWidget")
        return
    end
    
    if not self._original.FrontLightWidget_init then
        self._cached_modules["ui/widget/frontlightwidget"] = FrontLightWidget
        self._original.FrontLightWidget_init = FrontLightWidget.init
    end
    
    local theme = self
    local max_content_width = self._cached_max_content_width
    local border_size = self.BORDER_SIZE
    
    FrontLightWidget.init = function(widget_self)
        local layout_method = getmetatable(widget_self).layout
        
        theme._original.FrontLightWidget_init(widget_self)
        
        local content_width = max_content_width - (border_size * 2) - 2
        widget_self.width = content_width
        widget_self.inner_width = widget_self.width - 2 * require("ui/size").padding.large
        widget_self.button_width = math.floor(widget_self.inner_width / 4)
        
        layout_method(widget_self)
    end
    
    logger.info("PocketBookTheme: Hooked FrontLightWidget")
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
    
    if not self._original.DictQuickLookup_init then
        self._original.DictQuickLookup_init = DictQuickLookup.init
    end
    
    local max_width = self._cached_max_content_width
    local border_size = self.BORDER_SIZE
    local Size = require("ui/size")
    local theme = self
    
    DictQuickLookup.new = function(class, args)
        if not args.is_wiki then
            args.width = max_width - (border_size * 2) - 2
        end
        return theme._original.DictQuickLookup_new(class, args)
    end
    
    DictQuickLookup.init = function(widget_self)
        if widget_self.is_wiki then
            local original_funcs = {
                getSize = Screen.getSize,
                getWidth = Screen.getWidth,
                getHeight = Screen.getHeight
            }
            
            local screen_size = original_funcs.getSize(Screen)
            local target_width = math.floor(screen_size.w * theme.WIKIPEDIA_WIDTH_PERCENT)
            local target_height = math.floor(screen_size.h * theme.WIKIPEDIA_HEIGHT_PERCENT)
            local margin = Size.margin.default or 0
            local fake_width = target_width + (2 * margin)
            
            Screen.getSize = function() return { w = fake_width, h = target_height } end
            Screen.getWidth = function() return fake_width end
            Screen.getHeight = function() return target_height end
            
            theme._original.DictQuickLookup_init(widget_self)
            
            Screen.getSize = original_funcs.getSize
            Screen.getWidth = original_funcs.getWidth
            Screen.getHeight = original_funcs.getHeight
            
            if widget_self[1] and widget_self[1].dimen then
                local real_screen_size = Screen:getSize()
                widget_self[1].dimen.x = math.floor((real_screen_size.w - target_width) / 2)
                widget_self[1].dimen.y = math.floor((real_screen_size.h - target_height) / 2)
                widget_self[1].dimen.w = target_width
                widget_self[1].dimen.h = target_height
            end
        else
            theme._original.DictQuickLookup_init(widget_self)
        end
    end
    
    logger.info("PocketBookTheme: Hooked DictQuickLookup for dictionary and Wikipedia")
end

-- ButtonTable Hook
function PocketBookTheme:_isCalledFromButtonDialog()
    for level = 2, 10 do
        local info = debug.getinfo(level, "S")
        if not info then break end
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
    
    -- Helper function to apply uppercase
    local function applyUppercase(btn)
        if btn.text then
            btn.text = Utf8Proc.uppercase_dumb(btn.text)
        end
        if btn.text_func then
            local original_text_func = btn.text_func
            btn.text_func = function()
                local text = original_text_func()
                return text and Utf8Proc.uppercase_dumb(text) or text
            end
        end
    end
    
    ButtonTable.new = function(class, args)
        if args.buttons then
            local is_buttondialog = theme:_isCalledFromButtonDialog()
            
            for _, row in ipairs(args.buttons) do
                for _, btn in ipairs(row) do
                    if not is_buttondialog then
                        applyUppercase(btn)
                    end
                    btn.font_bold = false
                end
            end
        end
        
        return theme._original.ButtonTable_new_global(class, args)
    end
    
    Button.new = function(class, args)
        local is_flat_button = (args.bordersize == 0 and args.margin == 0)
        
        if is_flat_button then
            local is_from_buttondialog = theme:_isCalledFromButtonDialog()
            
            args.radius = 0
            args.padding = 0
            args.padding_h = 0
            args.padding_v = 0
            args.height = theme.BUTTON_HEIGHT
            
            if not is_from_buttondialog then
                applyUppercase(args)
            end
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

-- CONSOLIDATED InfoMessage/ConfirmBox/MultiConfirmBox Hook
function PocketBookTheme:_hookInfoMessageAndConfirmBox()
    local widget_configs = {
        {name = "InfoMessage", path = "ui/widget/infomessage", has_buttons = false},
        {name = "ConfirmBox", path = "ui/widget/confirmbox", has_buttons = true},
        {name = "MultiConfirmBox", path = "ui/widget/multiconfirmbox", has_buttons = true},
    }
    
    local IconWidget = self:_requireCached("ui/widget/iconwidget")
    local TextBoxWidget = self:_requireCached("ui/widget/textboxwidget")
    local ButtonTable = self:_requireCached("ui/widget/buttontable")
    local VerticalSpan = self:_requireCached("ui/widget/verticalspan")
    local VerticalGroup = self:_requireCached("ui/widget/verticalgroup")
    local HorizontalSpan = self:_requireCached("ui/widget/horizontalspan")
    local HorizontalGroup = self:_requireCached("ui/widget/horizontalgroup")
    local Size = require("ui/size")
    
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
    
    -- Universal hook function for all three widgets
    local function createUniversalHook(widget_name, has_buttons)
        return function(widget)
            if theme._cached_custom_face then
                widget.face = theme._cached_custom_face
            end
            
            -- Save original functions
            local saved_funcs = {
                IconWidget_new = IconWidget.new,
                TextBoxWidget_new = TextBoxWidget.new,
                ButtonTable_new = has_buttons and ButtonTable.new or nil
            }
            
            -- Override IconWidget.new
            IconWidget.new = function(class, o)
                o = o or {}
                if not o.width and not o.height then
                    o.width = theme.ICON_SIZE
                    o.height = theme.ICON_SIZE
                    o.scale_factor = 0
                end
                return theme._original.IconWidget_new(class, o)
            end
            
            -- Override TextBoxWidget.new
            TextBoxWidget.new = function(class, o)
                o = o or {}
                if theme._cached_custom_face then
                    o.face = theme._cached_custom_face
                end
                if o.width and o.width > theme._cached_text_width then
                    o.width = theme._cached_text_width
                end
                return theme._original.TextBoxWidget_new(class, o)
            end
            
            -- Override ButtonTable.new if widget has buttons
            if has_buttons then
                ButtonTable.new = function(class, args)
                    theme:_styleButtonsForWidget(args.buttons, widget_name)
                    args.width = theme._cached_available_content_width
                    return theme._original.ButtonTable_new_confirmbox(class, args)
                end
            end
            
            -- Call original init
            theme._original[widget_name .. "_init"](widget)
            
            -- Apply padding based on widget structure
            if widget_name == "InfoMessage" then
                -- InfoMessage: add padding on all sides including right
                if widget.movable and widget.movable[1] and widget.movable[1][1] then
                    local frame_container = widget.movable[1]
                    local old_horizontal_group = frame_container[1]
                    
                    local new_horizontal_group = HorizontalGroup:new{align = old_horizontal_group.align or "center"}
                    for i = 1, #old_horizontal_group do
                        table.insert(new_horizontal_group, old_horizontal_group[i])
                    end
                    table.insert(new_horizontal_group, HorizontalSpan:new{width = theme.TEXT_PADDING_VERTICAL})
                    
                    local content_with_padding = VerticalGroup:new{
                        align = "left",
                        VerticalSpan:new{width = theme.TEXT_PADDING_VERTICAL},
                        new_horizontal_group,
                        VerticalSpan:new{width = theme.TEXT_PADDING_VERTICAL},
                    }
                    frame_container[1] = content_with_padding
                end
            else
                -- ConfirmBox and MultiConfirmBox: only add vertical padding (top and bottom)
                local container_path = {
                    ConfirmBox = function() return widget.movable and widget.movable[1] end,
                    MultiConfirmBox = function() return widget[1] and widget[1][1] and widget[1][1][1] end,
                }
                
                local frame_container = container_path[widget_name]()
                if frame_container then
                    local vertical_group = frame_container[1]
                    if vertical_group then
                        -- Only add vertical spans, no horizontal padding
                        table.insert(vertical_group, 1, VerticalSpan:new{width = theme.TEXT_PADDING_VERTICAL})
                        table.insert(vertical_group, 3, VerticalSpan:new{width = theme.TEXT_PADDING_VERTICAL})
                        vertical_group:resetLayout()
                    end
                end
            end
            
            -- Restore original functions
            IconWidget.new = saved_funcs.IconWidget_new
            TextBoxWidget.new = saved_funcs.TextBoxWidget_new
            if saved_funcs.ButtonTable_new then
                ButtonTable.new = saved_funcs.ButtonTable_new
            end
        end
    end
    
    -- Apply hooks to all three widgets
    for _, config in ipairs(widget_configs) do
        local widget_class = self:_requireCached(config.path)
        if not self._original[config.name .. "_init"] then
            self._original[config.name .. "_init"] = widget_class.init
        end
        widget_class.init = createUniversalHook(config.name, config.has_buttons)
    end
    
    logger.info("PocketBookTheme: InfoMessage, ConfirmBox and MultiConfirmBox hooked")
end

function PocketBookTheme:_unhookInfoMessageAndConfirmBox()
    local widgets = {"InfoMessage", "ConfirmBox", "MultiConfirmBox"}
    local paths = {
        "ui/widget/infomessage",
        "ui/widget/confirmbox",
        "ui/widget/multiconfirmbox"
    }
    
    for i, widget_name in ipairs(widgets) do
        if self._original[widget_name .. "_init"] then
            local widget_class = self:_requireCached(paths[i])
            widget_class.init = self._original[widget_name .. "_init"]
            self._original[widget_name .. "_init"] = nil
        end
    end
    
    self._original.IconWidget_new = nil
    self._original.TextBoxWidget_new = nil
    self._original.ButtonTable_new_confirmbox = nil
end

function PocketBookTheme:_hookUIManagerShow()
    local UIManager = self:_requireCached("ui/uimanager")
    
    if not self._original.UIManager_show then
        self._original.UIManager_show = UIManager.show
    end
    
    local theme = self
    
    UIManager.show = function(self_ui, widget, ...)
        -- Get widget type for debugging
        local widget_type = "unknown"
        if widget then
            -- Method 1: Check for _name field (common in KOReader widgets)
            if widget._name then
                widget_type = widget._name
            else
                -- Method 2: Try _getWidgetType helper
                local type_from_helper = theme:_getWidgetType(widget)
                if type_from_helper then
                    widget_type = type_from_helper
                else
                    -- Method 3: Get from metatable __index
                    local mt = getmetatable(widget)
                    if mt and mt.__index then
                        -- Try to find module name by checking debug info of methods
                        for key, value in pairs(mt.__index) do
                            if type(value) == "function" then
                                local info = debug.getinfo(value, "S")
                                if info and info.source then
                                    local name = info.source:match("widget/([^/]+)%.lua")
                                    if name then
                                        widget_type = name
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        else
            widget_type = "nil"
        end
        
        local should_apply = widget and theme:_shouldApplyFrame(widget) or false
        
        logger.dbg(string.format("PocketBookTheme: UIManager:show - widget_type=%s, should_apply=%s",
                                 widget_type, tostring(should_apply)))
        
        if should_apply then
            theme:_applyThemedFrame(widget)
        end
        
        return theme._original.UIManager_show(self_ui, widget, ...)
    end
end

-- OPTIMIZED: Cache widget types once and use helper function
function PocketBookTheme:_getWidgetType(widget)
    if not widget then return nil end
    
    -- Initialize widget types cache
    if not self._widget_types then
        self._widget_types = {}
        for _, class_path in ipairs(self.WIDGET_CLASSES) do
            local success, widget_class = pcall(require, class_path)
            if success and widget_class then
                local class_name = class_path:match("([^/]+)$")
                self._widget_types[class_name] = widget_class
            end
        end
    end
    
    local mt = getmetatable(widget)
    if not mt then return nil end
    
    -- Check direct match and inheritance chain
    local check_mt = mt
    while check_mt do
        for class_name, widget_class in pairs(self._widget_types) do
            if check_mt == widget_class then
                return class_name
            end
        end
        check_mt = getmetatable(check_mt)
    end
    
    return nil
end

function PocketBookTheme:_shouldApplyFrame(widget)
    if widget._pocketbook_themed or self._processed_widgets[widget] then
        return false
    end
    
    local widget_type = self:_getWidgetType(widget)
    
    -- Support custom widgets with movable container
    if not widget_type and widget.movable then
        -- Check if it has the expected structure (movable with FrameContainer)
        local frame = widget.movable and widget.movable[1]
        if frame and type(frame) == "table" and frame.bordersize ~= nil then
            return true
        end
    end
    
    if not widget_type then
        return false
    end
    
    -- Skip fullscreen InputDialog and MultiInputDialog
    if (widget_type == "inputdialog" or widget_type == "multiinputdialog") and widget.fullscreen then
        return false
    end
    
    return true
end

function PocketBookTheme:_applyThemedFrame(widget)
    local widget_type = self:_getWidgetType(widget)
    
    -- Get movable container and frame based on widget structure
    local movable, old_frame
    
    -- Check for custom plugin widgets with movable container first
    if not widget_type and widget.movable then
        movable = widget.movable
        old_frame = widget.movable[1]
        widget_type = "custom_plugin"
    else
        local structure_map = {
            infomessage = function() return widget.movable, widget.movable and widget.movable[1] end,
            confirmbox = function() return widget.movable, widget.movable and widget.movable[1] end,
            multiconfirmbox = function() 
                if widget[1] and widget[1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            buttondialog = function()
                if widget[1] and widget[1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            inputdialog = function()
                if widget[1] and widget[1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            multiinputdialog = function()
                if widget[1] and widget[1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            dictquicklookup = function()
                if widget[1] and widget[1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            spinwidget = function() return widget.movable, widget.spin_frame end,
            textviewer = function() return widget.movable, widget.frame end,
            frontlightwidget = function()
                if widget[1] and widget[1][1] and widget[1][1][1] then
                    return widget[1][1], widget[1][1][1]
                end
            end,
            summary = function() return widget.movable, widget.movable and widget.movable[1] end,
        }
        
        local get_structure = structure_map[widget_type]
        if not get_structure then 
            return false 
        end
        
        movable, old_frame = get_structure()
    end
    
    if not movable or not old_frame then 
        return false 
    end
    
    local content = old_frame[1]
    if not content then 
        return false 
    end
    
    widget._pocketbook_themed = true
    self._processed_widgets[widget] = true
    
    local original_padding = old_frame.padding or 0
    
    local inner_frame = FrameContainer:new{
        radius = self._cached_inner_radius,
        bordersize = 1,
        color = Blitbuffer.COLOR_BLACK,
        background = old_frame.background or Blitbuffer.COLOR_WHITE,
        padding = 0,
        padding_top = old_frame.padding_top or original_padding,
        padding_bottom = old_frame.padding_bottom or original_padding,
        padding_left = old_frame.padding_left or original_padding,
        padding_right = old_frame.padding_right or original_padding,
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
    
    -- Update frame references for specific widgets
    if widget_type == "spinwidget" then
        widget.spin_frame = outer_frame
    elseif widget_type == "textviewer" then
        widget.frame = outer_frame
    elseif widget_type == "frontlightwidget" then
        widget.frame = outer_frame
    end
    
    -- Position at bottom for InfoMessage and ConfirmBox
    if (widget_type == "infomessage" or widget_type == "confirmbox") and 
       self:_shouldPositionAtBottom(widget) then
        self:_positionAtBottom(widget)
    end
    
    return true
end

-- Bottom Positioning
function PocketBookTheme:_shouldPositionAtBottom(widget)
    local widget_type = self:_getWidgetType(widget)
    
    return (widget.text and widget.face and not widget.buttons) or
           widget_type == "confirmbox" or
           (widget.text and widget.face and widget.buttons and (widget.ok_text or widget.cancel_text))
end

function PocketBookTheme:_positionAtBottom(widget)
    if not widget[1] then return end
    
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
    if not buttons then return end
    
    local Utf8Proc = require("ffi/utf8proc")
    local apply_uppercase = (widget_type ~= "ButtonDialog")
    
    for _, row in ipairs(buttons) do
        for _, btn in ipairs(row) do
            if btn.text and apply_uppercase then
                btn.text = Utf8Proc.uppercase_dumb(btn.text)
            end
            btn.height = self.BUTTON_HEIGHT
            btn.font_bold = false
        end
    end
end

return PocketBookTheme