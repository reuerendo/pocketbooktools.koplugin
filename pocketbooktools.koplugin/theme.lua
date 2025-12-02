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
    _patches = {
        { module = "ui/widget/infomessage", method = "init", key = "InfoMessage_init" },
        { module = "ui/widget/confirmbox", method = "init", key = "ConfirmBox_init" },
        { module = "ui/widget/buttondialog", method = "init", key = "ButtonDialog_init" },
        { module = "ui/widget/buttontable", method = "init", key = "ButtonTable_init" },
    }
}

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

function PocketBookTheme:_applyTheme()
    self:_patchInfoMessage()
    self:_patchConfirmBox()
    self:_patchButtonDialog()
    self:_patchButtonTable()
end

function PocketBookTheme:_restoreOriginal()
    for _, patch in ipairs(self._patches) do
        if self._original[patch.key] then
            local WidgetModule = require(patch.module)
            WidgetModule[patch.method] = self._original[patch.key]
            self._original[patch.key] = nil
            logger.dbg("PocketBookTheme: Restored", patch.key)
        end
    end
    
    self:_unpatchSizeModule()
    self:_restoreSizeOverrides()
    self:_unpatchIconWidget()
end

-- Helper: Font Preparation
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

-- Helper: Create Nested Frames
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

function PocketBookTheme:_patchButtonTable()
    local ButtonTable = require("ui/widget/buttontable")
    
    if not self._original.ButtonTable_init then
        self._original.ButtonTable_init = ButtonTable.init
    end
    
    local theme = self
    
    local cyrillic_map = {
        ['а'] = 'А', ['б'] = 'Б', ['в'] = 'В', ['г'] = 'Г', ['д'] = 'Д',
        ['е'] = 'Е', ['ё'] = 'Ё', ['ж'] = 'Ж', ['з'] = 'З', ['и'] = 'И',
        ['й'] = 'Й', ['к'] = 'К', ['л'] = 'Л', ['м'] = 'М', ['н'] = 'Н',
        ['о'] = 'О', ['п'] = 'П', ['р'] = 'Р', ['с'] = 'С', ['т'] = 'Т',
        ['у'] = 'У', ['ф'] = 'Ф', ['х'] = 'Х', ['ц'] = 'Ц', ['ч'] = 'Ч',
        ['ш'] = 'Ш', ['щ'] = 'Щ', ['ъ'] = 'Ъ', ['ы'] = 'Ы', ['ь'] = 'Ь',
        ['э'] = 'Э', ['ю'] = 'Ю', ['я'] = 'Я',
    }

    local function utf8_upper(text)
        if not text then return text end
        local result = string.upper(text)
        for lower, upper in pairs(cyrillic_map) do
            result = result:gsub(lower, upper)
        end
        return result
    end
    
    ButtonTable.init = function(widget)
        if widget.buttons then
            for _, row in ipairs(widget.buttons) do
                for _, btn in ipairs(row) do
                    if btn.text then btn.text = utf8_upper(btn.text) end
                    if not btn.height then btn.height = theme.BUTTON_HEIGHT end
                    
                    if theme.FONT_FACE ~= "infofont" and theme.FONT_PATH then
                        btn.font_face = theme.FONT_FACE
                        btn.font_bold = false
                    else
                        btn.font_bold = false
                    end
                end
            end
        end
        PocketBookTheme._original.ButtonTable_init(widget)
    end
    
    logger.dbg("PocketBookTheme: ButtonTable patched")
end

function PocketBookTheme:_patchInfoMessage()
    local InfoMessage = require("ui/widget/infomessage")
    
    if not self._original.InfoMessage_init then
        self._original.InfoMessage_init = InfoMessage.init
    end
    
    local theme = self
    
    InfoMessage.init = function(widget)
        local screen_width = Screen:getSize().w
        local max_width = math.floor(screen_width * theme.MAX_WIDTH_PERCENT)
        widget.width = max_width - (theme.PADDING_HORIZONTAL * 2)
        
        local face = theme:_prepareFont()
        widget.face = face
        if theme.FONT_FACE ~= "infofont" then
            widget.monospace_font = false
        end
        
        widget._pb_icon_size = theme.ICON_SIZE
        
        theme:_patchSizeModule()
        theme:_patchIconWidget()
        
        PocketBookTheme._original.InfoMessage_init(widget)
        
        theme:_unpatchSizeModule()
        theme:_unpatchIconWidget()
        
        -- Post init styling
        -- FIX: Extract content from the existing frame to avoid double borders
        local existing_frame = widget.movable[1]
        local inner_content = existing_frame[1]
        
        local new_frame = theme:_createThemedFrame(inner_content, {
            left = theme.PADDING_HORIZONTAL,
            right = theme.PADDING_HORIZONTAL,
            top = theme.PADDING_VERTICAL,
            bottom = theme.PADDING_VERTICAL
        })
        widget.movable[1] = new_frame
        
        theme:_positionAtBottom(widget)
    end
    
    logger.dbg("PocketBookTheme: InfoMessage patched")
end

function PocketBookTheme:_patchConfirmBox()
    local ConfirmBox = require("ui/widget/confirmbox")
    
    if not self._original.ConfirmBox_init then
        self._original.ConfirmBox_init = ConfirmBox.init
    end
    
    local theme = self
    
    ConfirmBox.init = function(widget)
        widget.width_factor = theme.MAX_WIDTH_PERCENT
        widget.face = theme:_prepareFont()
        
        theme:_patchSizeModule()
        theme:_patchIconWidget()
        
        PocketBookTheme._original.ConfirmBox_init(widget)
        
        theme:_unpatchSizeModule()
        theme:_unpatchIconWidget()
        
        -- Post init styling
        local inner_frame_obj = widget.movable[1]
        local vertical_group = inner_frame_obj[1]
        
        if vertical_group then
            local button_table_index = nil
            for i = #vertical_group, 1, -1 do
                if vertical_group[i].buttons then
                    button_table_index = i
                    break
                end
            end
            
            if button_table_index and button_table_index > 1 then
                table.insert(vertical_group, button_table_index, VerticalSpan:new{ width = theme.PADDING_VERTICAL })
                if vertical_group.resetLayout then vertical_group:resetLayout() end
            end
        end
        
        local new_frame = theme:_createThemedFrame(vertical_group, {
            left = theme.PADDING_HORIZONTAL,
            right = theme.PADDING_HORIZONTAL,
            top = theme.PADDING_VERTICAL,
            bottom = 0 
        })
        widget.movable[1] = new_frame
        
        theme:_positionAtBottom(widget)
    end
    
    logger.dbg("PocketBookTheme: ConfirmBox patched")
end

function PocketBookTheme:_patchButtonDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    
    if not self._original.ButtonDialog_init then
        self._original.ButtonDialog_init = ButtonDialog.init
    end
    
    local theme = self
    
    ButtonDialog.init = function(widget)
        local screen_width = Screen:getSize().w
        local target_width = math.floor(screen_width * theme.MAX_WIDTH_PERCENT)
        
        if not theme._size_overrides_applied then
            theme._original_size_padding_button = Size.padding.button
            theme._original_size_border_window = Size.border.window
            theme._original_size_radius_window = Size.radius.window
            
            Size.padding.button = 0
            Size.border.window = theme.BORDER_SIZE
            Size.radius.window = theme.RADIUS
            theme._size_overrides_applied = true
        end
        
        widget.width = target_width + 2*theme.BORDER_SIZE
        
        local face = theme:_prepareFont()
        widget.title_face = face
        widget.info_face = face
        
        local status, err = pcall(function()
            PocketBookTheme._original.ButtonDialog_init(widget)
        end)
        
        theme:_restoreSizeOverrides()
        
        if not status then
            logger.warn("PocketBookTheme: ButtonDialog init failed:", err)
            return
        end
        
        -- Post init styling
        local old_frame = widget.movable[1]
        local frame_content = old_frame[1]
        
        local new_frame = theme:_createThemedFrame(frame_content, {
            left = theme.PADDING_HORIZONTAL,
            right = theme.PADDING_HORIZONTAL,
            top = theme.PADDING_VERTICAL,
            bottom = 0
        })
        widget.movable[1] = new_frame
        
        theme:_positionAtBottom(widget)
    end
    
    logger.dbg("PocketBookTheme: ButtonDialog patched")
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

function PocketBookTheme:_restoreSizeOverrides()
    if self._size_overrides_applied then
        Size.padding.button = self._original_size_padding_button
        Size.border.window = self._original_size_border_window
        Size.radius.window = self._original_size_radius_window
        self._size_overrides_applied = false
    end
end

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

return PocketBookTheme