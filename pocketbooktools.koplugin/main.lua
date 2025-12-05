local Device = require("device")

if not Device:isPocketBook() then
    return { disabled = true, }
end

local InfoMessage = require("ui/widget/infomessage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffi = require("ffi")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local inkview = ffi.load("inkview")
local pocketbook_db_conn = SQ3.open("/mnt/ext1/system/explorer-3/explorer-3.db")
pocketbook_db_conn:set_busy_timeout(2000)

-- Cache frequently used settings keys
local END_ACTION_KEY = "end_document_action"
local SHOW_SUMMARY_VALUE = "show_book_summary"

-- Patch for adding "Show book summary" to document end actions
local original_dofile = dofile
local summary_patch_applied = false

_G.dofile = function(filepath)
    local result = original_dofile(filepath)
    
    -- Check if we need to patch and if the target file is loaded
    if not summary_patch_applied and filepath and filepath:match("common_settings_menu_table%.lua$") then
        -- Verify result structure exists
        if result and result.document_end_action and result.document_end_action.sub_item_table then
            local sub_table = result.document_end_action.sub_item_table
            
            table.insert(sub_table, 2, {
                text = _("Show book summary"),
                checked_func = function()
                    return G_reader_settings:readSetting(END_ACTION_KEY) == SHOW_SUMMARY_VALUE
                end,
                radio = true,
                callback = function()
                    G_reader_settings:saveSetting(END_ACTION_KEY, SHOW_SUMMARY_VALUE)
                end,
            })
            summary_patch_applied = true
            
            logger.dbg("PocketbookTools: Successfully patched document_end_action menu")
        else
            logger.warn("PocketbookTools: Failed to patch document_end_action menu - structure not found")
        end
    end
    
    return result
end

local PocketbookTools = WidgetContainer:extend{
    name = "NULL;",
    is_doc_only = false,
}

local COLLECTION_INFO_TEXT = _([[
The function allows you to automatically remove a book from a specified collection after reading it.]])

local THEME_INFO_TEXT = _([[
Apply PocketBook native style to dialogs and messages.]])

local ABOUT_TEXT = _([[
A KOReader plugin that syncs reading progress from KOReader to PocketBook Library.]])

function PocketbookTools:init()
    self.ui.menu:registerToMainMenu(self)
    table.insert(self.ui.active_widgets, self)
    self:resetCache()
    
    local PocketBookTheme = require("theme")
    PocketBookTheme:init()
    
    self:registerSummaryAction()
    self:patchDocumentEndAction()
end

function PocketbookTools:patchDocumentEndAction()
    -- Trigger patching by scheduling check
    UIManager:scheduleIn(1, function()
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance and ReaderUI.instance.menu then
            logger.dbg("PocketbookTools: Triggering document end action menu patch")
        end
    end)
end

function PocketbookTools:registerSummaryAction()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("show_book_summary", {
        category = "none",
        event = "ShowBookSummary",
        title = _("Show Book Summary"),
        general = false,
        filemanager = false,
        reader = true,
    })
end

function PocketbookTools:onShowBookSummary()
    if not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No document open"),
            timeout = 2,
        })
        return true
    end
    
    -- Update progress data before showing dialog
    local sync_data = self:_prepareSync()
    if sync_data then
        logger.dbg("PocketbookTools: Progress data updated for summary dialog")
    end
    
    local SummaryDialog = require("summary")
    local dialog = SummaryDialog:new{
        ui = self.ui,
    }
    
    UIManager:show(dialog)
    return true
end

function PocketbookTools:onEndOfBook()
    local end_action = G_reader_settings:readSetting(END_ACTION_KEY)
    
    if end_action == SHOW_SUMMARY_VALUE then
        -- Flush settings before showing summary
        if self.ui.document then
            self.ui:onFlushSettings()
            
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("FlushSettings"))
        end
        
        -- Show summary dialog
        self:onShowBookSummary()
        return true
    end
    
    return false
end

function PocketbookTools:resetCache()
    self.current_pb_book_id = nil
    self.current_profile_id = nil
    self.current_folder_id = nil
    self.current_flow = nil
    self.last_synced_page = -1
    self.last_sync_timestamp = 0
    self.db_error_count = 0
end

function PocketbookTools:addToMainMenu(menu_items)
    menu_items.pocketbook_sync = {
        sorting_hint = "tools",
        text = _("PocketBook Tools"),
        sub_item_table = {
            {
                text = _("About Pocketbook Tools"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = ABOUT_TEXT,
                    })
                end,
                keep_menu_open = true,
                separator = true,
            },
            {
                text = _("Show Book Summary"),
                enabled_func = function()
                    return self.ui.document ~= nil
                end,
                callback = function()
                    self:onShowBookSummary()
                end,
                separator = true,
            },
            self:getCollectionMenuTable(),
            self:getThemeMenuTable(),
        }
    }
end

function PocketbookTools:getThemeMenuTable()
    return {
        text = _("PocketBook Style"),
        checked_func = function()
            return G_reader_settings:isTrue("pocketbook_theme_enabled")
        end,
        callback = function()
            local PocketBookTheme = require("theme")
            if PocketBookTheme:isEnabled() then
                PocketBookTheme:disable()
                UIManager:show(InfoMessage:new{
                    text = _("PocketBook style disabled. Restart KOReader for changes to take full effect."),
                    timeout = 3,
                })
            else
                PocketBookTheme:enable()
                UIManager:show(InfoMessage:new{
                    text = _("PocketBook style enabled. Restart KOReader for changes to take full effect."),
                    timeout = 3,
                })
            end
        end,
        help_text = THEME_INFO_TEXT,
    }
end

function PocketbookTools:getCollectionMenuTable()
    local collections = self:getKOReaderCollections()
    local sub_item_table = {}
    
    -- Add "None" option
    table.insert(sub_item_table, {
        text = _("None (disable auto-removal)"),
        checked_func = function()
            return G_reader_settings:readSetting("to_read_collection_name") == nil
        end,
        callback = function()
            G_reader_settings:delSetting("to_read_collection_name")
            G_reader_settings:delSetting("to_read_collection_id")
            G_reader_settings:flush()
            logger.info("PocketbookTools: Collection settings cleared")
            UIManager:show(InfoMessage:new{
                text = _("Auto-removal disabled"),
                timeout = 2,
            })
        end,
        radio = true,
        separator = true,
    })
    
    -- Add all collections
    for i, coll_name in ipairs(collections) do
        table.insert(sub_item_table, {
            text = coll_name,
            checked_func = function()
                return coll_name == G_reader_settings:readSetting("to_read_collection_name")
            end,
            callback = function()
                self:_saveCollectionSettings(coll_name)
                UIManager:show(InfoMessage:new{
                    text = T(_("Collection set: %1"), coll_name),
                    timeout = 2,
                })
            end,
            radio = true,
        })
    end 
    
    return {
        text_func = function()
            local collection_name = G_reader_settings:readSetting("to_read_collection_name")
            if collection_name then
                return T(_("Remove a finished book from: %1"), collection_name)
            else
                return _("Remove a finished book from: None")
            end
        end,
        sub_item_table = sub_item_table,
        help_text = COLLECTION_INFO_TEXT,
    }
end

function PocketbookTools:getKOReaderCollections()
    local success, ReadCollection = pcall(require, "readcollection")
    if not success then
        logger.warn("PocketbookTools: ReadCollection module not available")
        return {}
    end
    
    local collections = {}
    for coll_name in pairs(ReadCollection.coll) do
        table.insert(collections, coll_name)
    end
    
    table.sort(collections)
    return collections
end

function PocketbookTools:getCollectionIdByName(name)
    if not name or name == "" then return nil end
    
    local stmt = pocketbook_db_conn:prepare(
        "SELECT id FROM bookshelfs WHERE name = ? AND is_deleted != 1 LIMIT 1"
    )
    local row = stmt:reset():bind(name):step()
    stmt:close()
    
    if row == nil then
        logger.info("PocketbookTools: Collection '" .. name .. "' not found")
        return nil
    end
    
    local id_str = tostring(row[1]):gsub("LL$", "")
    local id_num = tonumber(id_str)
    return id_num
end

function PocketbookTools:removeFromKOReaderCollection(book_path, collection_name)
    if not collection_name or collection_name == "" then return end
    
    local success, ReadCollection = pcall(require, "readcollection")
    if not success then return end
    
    local collections = ReadCollection.coll
    if not collections or not collections[collection_name] then return end
    
    if collections[collection_name][book_path] then
        collections[collection_name][book_path] = nil
        logger.info("PocketbookTools: Removed book from KOReader collection '" .. collection_name .. "'")
        ReadCollection:saveCollections()
    end
end

function PocketbookTools:onCloseDocument()
    logger.dbg("PocketbookTools: onCloseDocument triggered")
    self:_handleSessionEnd("close")
    return false
end

function PocketbookTools:onSuspend()
    logger.dbg("PocketbookTools: onSuspend triggered")
    
    -- Call PageSnapshot ONLY here - this is the right place for screen capture
    local snapshot_success, snapshot_err = pcall(inkview.PageSnapshot)
    if not snapshot_success then
        logger.warn("PocketbookTools: PageSnapshot failed: " .. tostring(snapshot_err))
    end
    
    self:_handleSessionEnd("suspend")
    return false
end

function PocketbookTools:onExit()
    logger.dbg("PocketbookTools: onExit triggered")
    -- Don't sync if we just closed a document (prevent duplicate sync)
    local now = os.time()
    if now - self.last_sync_timestamp < 2 then
        logger.dbg("PocketbookTools: Skipping exit sync - recently synced")
        return false
    end
    
    self:_handleSessionEnd("exit")
    return false
end

function PocketbookTools:_handleSessionEnd(source)
    if not self.ui.document then 
        logger.dbg("PocketbookTools: No document open, skipping sync")
        return 
    end

    self:sync()
    
    -- Reset cache after close/exit, but not after suspend
    if source == "close" or source == "exit" then
        self:resetCache()
    end
end

function PocketbookTools:sync()
    -- Check database health
    if self.db_error_count >= 3 then
        logger.error("PocketbookTools: Too many database errors, disabling sync")
        return
    end
    
    local sync_data = self:_prepareSync()
    if sync_data then
        self:_doSync(sync_data)
    end
end

function PocketbookTools:_saveCollectionSettings(name)
    local collection_id = self:getCollectionIdByName(name)
    
    G_reader_settings:saveSetting("to_read_collection_name", name)
    
    if collection_id then
        G_reader_settings:saveSetting("to_read_collection_id", collection_id)
        logger.info("PocketbookTools: Collection ID saved: " .. collection_id)
    else
        G_reader_settings:delSetting("to_read_collection_id")
    end
    G_reader_settings:flush()
end

function PocketbookTools:_prepareSync()
    if not self.ui.document then return nil end

    local folder, file = self:_getFolderFile()
    if not folder or folder == "" or not file or file == "" then 
        logger.warn("PocketbookTools: Invalid folder or file path")
        return nil 
    end

    local global_page = self.view.state.page
    
    -- Cache flow value as it doesn't change for a document
    if not self.current_flow then
        self.current_flow = self.document:getPageFlow(global_page)
    end
    
    local flow = self.current_flow

    if flow ~= 0 then 
        logger.dbg("PocketbookTools: Skipping non-linear flow")
        return nil 
    end

    local total_pages = self.document:getTotalPagesInFlow(flow)
    local page = self.document:getPageNumberInFlow(global_page)
    local summary = self.ui.doc_settings:readSetting("summary")
    local status = summary and summary.status
    local is_completed = (status == "complete" or page == total_pages) and 1 or 0

    -- Save progress_ratio (0.0-1.0) instead of percent (0-100)
    local progress_ratio = 0
    if total_pages > 0 then
        progress_ratio = page / total_pages
    end

    -- Save progress to KOReader settings
    self.ui.doc_settings:saveSetting("pocketbook_sync_progress", {
        ratio = progress_ratio,
        percent = math.ceil(progress_ratio * 100),
        current_page = page,
        total_pages = total_pages,
        last_sync = os.time()
    })

    -- PocketBook uses 0-based page indexing
    if page == 1 then page = 0 end

    return {
        folder = folder,
        file = file,
        total_pages = total_pages,
        page = page,
        is_completed = is_completed,
        time = os.time(),
        book_path = self.view.document.file,
    }
end

function PocketbookTools:_doSync(data)
    if not data then return end

    -- Prevent duplicate syncs (unless marking as complete)
    if data.page == self.last_synced_page and data.is_completed ~= 1 then
        logger.dbg("PocketbookTools: Same page, skipping sync")
        return
    end

    local book_id = self:_getBookIdCached(data.folder, data.file)
    
    if not book_id then 
        logger.warn("PocketbookTools: Book not found in PocketBook database")
        return 
    end

    local success = self:_updatePocketBookProgress(book_id, data)
    
    if success then
        self.last_synced_page = data.page
        self.last_sync_timestamp = os.time()
        
        if data.is_completed == 1 then
            self:_removeFromCollectionsOnComplete(book_id, data.book_path)
        end
    end
end

function PocketbookTools:_getBookIdCached(folder, file)
    if self.current_pb_book_id then
        return self.current_pb_book_id
    end

    -- Get folder_id first and cache it
    if not self.current_folder_id then
        local folder_stmt = pocketbook_db_conn:prepare(
            "SELECT id FROM folders WHERE name = ? LIMIT 1"
        )
        local folder_row = folder_stmt:reset():bind(folder):step()
        folder_stmt:close()
        
        if not folder_row then
            logger.info("PocketbookTools: Folder not found: " .. folder)
            return nil
        end
        
        self.current_folder_id = folder_row[1]
    end

    -- Now get book_id using cached folder_id
    local sql = "SELECT book_id FROM files WHERE folder_id = ? AND filename = ? LIMIT 1"
    local stmt = pocketbook_db_conn:prepare(sql)
    local row = stmt:reset():bind(self.current_folder_id, file):step()
    stmt:close()

    if row == nil then
        logger.info("PocketbookTools: Book not found in database")
        return nil
    end
    
    self.current_pb_book_id = row[1]
    return self.current_pb_book_id
end

function PocketbookTools:_updatePocketBookProgress(book_id, data)
    local sql = [[
        REPLACE INTO books_settings
        (bookid, profileid, cpage, npage, completed, opentime)
        VALUES (?, ?, ?, ?, ?, ?)
    ]]
    
    local success = false
    
    -- Wrap in protected call with proper error handling
    local db_success, db_err = pcall(function()
        pocketbook_db_conn:exec("BEGIN TRANSACTION")
        
        local stmt = pocketbook_db_conn:prepare(sql)
        local profile_id = self:_getCurrentProfileIdCached()
        stmt:reset():bind(book_id, profile_id, data.page, data.total_pages,
                          data.is_completed, data.time):step()
        stmt:close()
        
        pocketbook_db_conn:exec("COMMIT")
        success = true
        logger.dbg("PocketbookTools: Progress updated - page " .. data.page .. "/" .. data.total_pages)
    end)
    
    if not db_success then
        logger.error("PocketbookTools: DB write failed: " .. tostring(db_err))
        pcall(function() pocketbook_db_conn:exec("ROLLBACK") end)
        self.db_error_count = self.db_error_count + 1
        success = false
    else
        -- Reset error counter on success
        self.db_error_count = 0
    end
    
    return success
end

function PocketbookTools:_removeFromCollectionsOnComplete(book_id, book_path)
    local collection_name = G_reader_settings:readSetting("to_read_collection_name")
    local collection_id = G_reader_settings:readSetting("to_read_collection_id")
    
    if collection_id and collection_id ~= "" then
        self:_removeFromPocketBookCollection(book_id, tonumber(collection_id))
    end
    
    if collection_name and collection_name ~= "" and book_path then
        self:removeFromKOReaderCollection(book_path, collection_name)
    end
end

function PocketbookTools:_removeFromPocketBookCollection(book_id, collection_id)
    logger.info("PocketbookTools: Removing from collection ID: " .. tostring(collection_id))
    
    -- Check if book is in collection first
    local check_sql = [[
        SELECT bookshelfid FROM bookshelfs_books 
        WHERE bookid = ? AND bookshelfid = ? LIMIT 1
    ]]
    local check_stmt = pocketbook_db_conn:prepare(check_sql)
    local check_row = check_stmt:reset():bind(book_id, collection_id):step()
    check_stmt:close()
    
    if not check_row then
        logger.dbg("PocketbookTools: Book not in collection, nothing to remove")
        return
    end
    
    -- Remove from collection
    local del_sql = "DELETE FROM bookshelfs_books WHERE bookid = ? AND bookshelfid = ?"
    
    local db_success, db_err = pcall(function()
        pocketbook_db_conn:exec("BEGIN TRANSACTION")
        local del_stmt = pocketbook_db_conn:prepare(del_sql)
        del_stmt:reset():bind(book_id, collection_id):step()
        del_stmt:close()
        pocketbook_db_conn:exec("COMMIT")
        logger.info("PocketbookTools: Successfully removed from collection")
    end)
    
    if not db_success then
        logger.error("PocketbookTools: Collection removal failed: " .. tostring(db_err))
        pcall(function() pocketbook_db_conn:exec("ROLLBACK") end)
    end
end

function PocketbookTools:_getFolderFile()
    if not self.view or not self.view.document or not self.view.document.file then
        return nil, nil
    end
    
    local path = self.view.document.file
    local folder, file = util.splitFilePathName(path)
    local folder_trimmed = folder:match("(.*)/")
    if folder_trimmed ~= nil then
        folder = folder_trimmed
    end
    return folder, file
end

function PocketbookTools:_getCurrentProfileIdCached()
    if self.current_profile_id then
        return self.current_profile_id
    end

    local profile_name = inkview.GetCurrentProfile()
    if profile_name == nil then
        self.current_profile_id = 1
    else
        local success, err = pcall(function()
            local stmt = pocketbook_db_conn:prepare("SELECT id FROM profiles WHERE name = ?")
            local row = stmt:reset():bind(ffi.string(profile_name)):step()
            stmt:close()
            self.current_profile_id = row and row[1] or 1
        end)
        
        if not success then
            logger.warn("PocketbookTools: Failed to get profile ID: " .. tostring(err))
            self.current_profile_id = 1
        end
    end
    
    return self.current_profile_id
end

return PocketbookTools