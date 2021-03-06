callWithJQuery = (pivotModule) ->
    if typeof exports is "object" and typeof module is "object" # CommonJS
        pivotModule require("jquery")
    else if typeof define is "function" and define.amd # AMD
        define ["jquery"], pivotModule
    # Plain browser env
    else
        pivotModule jQuery

callWithJQuery ($) ->

    ###
    Utilities
    ###

    addSeparators = (nStr, thousandsSep, decimalSep) ->
        nStr += ''
        x = nStr.split('.')
        x1 = x[0]
        x2 = if x.length > 1 then  decimalSep + x[1] else ''
        rgx = /(\d+)(\d{3})/
        x1 = x1.replace(rgx, '$1' + thousandsSep + '$2') while rgx.test(x1)
        return x1 + x2

    numberFormat = (opts) ->
        defaults =
            digitsAfterDecimal: 2, scaler: 1,
            thousandsSep: ",", decimalSep: "."
            prefix: "", suffix: ""
        opts = $.extend({}, defaults, opts)
        (x) ->
            return "" if isNaN(x) or not isFinite(x)
            result = addSeparators (opts.scaler*x).toFixed(opts.digitsAfterDecimal), opts.thousandsSep, opts.decimalSep
            return ""+opts.prefix+result+opts.suffix

    #aggregator templates default to US number formatting but this is overrideable
    usFmt = numberFormat()
    usFmtInt = numberFormat(digitsAfterDecimal: 0)
    usFmtPct = numberFormat(digitsAfterDecimal:1, scaler: 100, suffix: "%")

    aggregatorTemplates =
        count: (formatter=usFmtInt) -> () -> (data, rowKey, colKey) ->
            count: 0
            push:  -> @count++
            value: -> @count
            format: formatter

        uniques: (fn, formatter=usFmtInt) -> ([attr]) -> (data, rowKey, colKey) ->
            uniq: []
            push: (record) -> @uniq.push(record[attr]) if record[attr] not in @uniq
            value: -> fn(@uniq)
            format: formatter
            numInputs: if attr? then 0 else 1

        sum: (formatter=usFmt) -> ([attr]) -> (data, rowKey, colKey) ->
            sum: 0
            push: (record) -> @sum += parseFloat(record[attr]) if not isNaN parseFloat(record[attr])
            value: -> @sum
            format: formatter
            numInputs: if attr? then 0 else 1

        extremes: (mode, formatter=usFmt) -> ([attr]) -> (data, rowKey, colKey) ->
            val: null
            sorter: getSort(data?.sorters, attr)
            push: (record) ->
                x = record[attr]
                if mode in ["min", "max"]
                    x = parseFloat(x)
                    if not isNaN x then @val = Math[mode](x, @val ? x)
                if mode == "first" then @val = x if @sorter(x, @val ? x) <= 0
                if mode == "last"  then @val = x if @sorter(x, @val ? x) >= 0
            value: -> @val
            format: (x) -> if isNaN(x) then x else formatter(x)
            numInputs: if attr? then 0 else 1

        quantile: (q, formatter=usFmt) -> ([attr]) -> (data, rowKey, colKey) ->
            vals: []
            push: (record) ->
                x = parseFloat(record[attr])
                @vals.push(x) if not isNaN(x)
            value: ->
                return null if @vals.length == 0
                @vals.sort((a,b) -> a-b)
                i = (@vals.length-1)*q
                return (@vals[Math.floor(i)] + @vals[Math.ceil(i)])/2.0
            format: formatter
            numInputs: if attr? then 0 else 1

        runningStat: (mode="mean", ddof=1, formatter=usFmt) -> ([attr]) -> (data, rowKey, colKey) ->
            n: 0.0, m: 0.0, s: 0.0
            push: (record) ->
                x = parseFloat(record[attr])
                return if isNaN(x)
                @n += 1.0
                if @n == 1.0
                    @m = x
                else
                    m_new = @m + (x - @m)/@n
                    @s = @s + (x - @m)*(x - m_new)
                    @m = m_new
            value: ->
                if mode == "mean"
                    return if @n == 0 then 0/0 else @m
                return 0 if @n <= ddof
                switch mode
                    when "var"   then @s/(@n-ddof)
                    when "stdev" then Math.sqrt(@s/(@n-ddof))
            format: formatter
            numInputs: if attr? then 0 else 1

        sumOverSum: (formatter=usFmt) -> ([num, denom]) -> (data, rowKey, colKey) ->
            sumNum: 0
            sumDenom: 0
            push: (record) ->
                @sumNum   += parseFloat(record[num])   if not isNaN parseFloat(record[num])
                @sumDenom += parseFloat(record[denom]) if not isNaN parseFloat(record[denom])
            value: -> @sumNum/@sumDenom
            format: formatter
            numInputs: if num? and denom? then 0 else 2

        sumOverSumBound80: (upper=true, formatter=usFmt) -> ([num, denom]) -> (data, rowKey, colKey) ->
            sumNum: 0
            sumDenom: 0
            push: (record) ->
                @sumNum   += parseFloat(record[num])   if not isNaN parseFloat(record[num])
                @sumDenom += parseFloat(record[denom]) if not isNaN parseFloat(record[denom])
            value: ->
                sign = if upper then 1 else -1
                (0.821187207574908/@sumDenom + @sumNum/@sumDenom + 1.2815515655446004*sign*
                    Math.sqrt(0.410593603787454/ (@sumDenom*@sumDenom) + (@sumNum*(1 - @sumNum/ @sumDenom))/ (@sumDenom*@sumDenom)))/
                    (1 + 1.642374415149816/@sumDenom)
            format: formatter
            numInputs: if num? and denom? then 0 else 2

        fractionOf: (wrapped, type="total", formatter=usFmtPct) -> (x...) -> (data, rowKey, colKey) ->
            selector: {total:[[],[]],row:[rowKey,[]],col:[[],colKey]}[type]
            inner: wrapped(x...)(data, rowKey, colKey)
            push: (record) -> @inner.push record
            format: formatter
            value: -> @inner.value() / data.getAggregator(@selector...).inner.value()
            numInputs: wrapped(x...)().numInputs

    aggregatorTemplates.countUnique = (f) -> aggregatorTemplates.uniques(((x) -> x.length), f)
    aggregatorTemplates.listUnique =  (s) -> aggregatorTemplates.uniques(((x) -> x.sort(naturalSort).join(s)), ((x)->x))
    aggregatorTemplates.max =         (f) -> aggregatorTemplates.extremes('max', f)
    aggregatorTemplates.min =         (f) -> aggregatorTemplates.extremes('min', f)
    aggregatorTemplates.first =       (f) -> aggregatorTemplates.extremes('first', f)
    aggregatorTemplates.last =        (f) -> aggregatorTemplates.extremes('last', f)
    aggregatorTemplates.median =      (f) -> aggregatorTemplates.quantile(0.5, f)
    aggregatorTemplates.average =     (f) -> aggregatorTemplates.runningStat("mean", 1, f)
    aggregatorTemplates.var =         (ddof, f) -> aggregatorTemplates.runningStat("var", ddof, f)
    aggregatorTemplates.stdev =       (ddof, f) -> aggregatorTemplates.runningStat("stdev", ddof, f)

    #default aggregators & renderers use US naming and number formatting
    aggregators = do (tpl = aggregatorTemplates) ->
        "Count":                tpl.count(usFmtInt)
        "Count Unique Values":  tpl.countUnique(usFmtInt)
        "List Unique Values":   tpl.listUnique(", ")
        "Sum":                  tpl.sum(usFmt)
        "Integer Sum":          tpl.sum(usFmtInt)
        "Average":              tpl.average(usFmt)
        "Median":               tpl.median(usFmt)
        "Sample Variance":      tpl.var(1, usFmt)
        "Sample Standard Deviation": tpl.stdev(1, usFmt)
        "Minimum":              tpl.min(usFmt)
        "Maximum":              tpl.max(usFmt)
        "First":                tpl.first(usFmt)
        "Last":                 tpl.last(usFmt)
        "Sum over Sum":         tpl.sumOverSum(usFmt)
        "80% Upper Bound":      tpl.sumOverSumBound80(true, usFmt)
        "80% Lower Bound":      tpl.sumOverSumBound80(false, usFmt)
        "Sum as Fraction of Total":     tpl.fractionOf(tpl.sum(),   "total", usFmtPct)
        "Sum as Fraction of Rows":      tpl.fractionOf(tpl.sum(),   "row",   usFmtPct)
        "Sum as Fraction of Columns":   tpl.fractionOf(tpl.sum(),   "col",   usFmtPct)
        "Count as Fraction of Total":   tpl.fractionOf(tpl.count(), "total", usFmtPct)
        "Count as Fraction of Rows":    tpl.fractionOf(tpl.count(), "row",   usFmtPct)
        "Count as Fraction of Columns": tpl.fractionOf(tpl.count(), "col",   usFmtPct)

    renderers =
        "Table":          (data, opts) ->   pivotTableRenderer(data, opts)
        "Table Barchart": (data, opts) -> $(pivotTableRenderer(data, opts)).barchart()
        "Heatmap":        (data, opts) -> $(pivotTableRenderer(data, opts)).heatmap("heatmap",    opts)
        "Row Heatmap":    (data, opts) -> $(pivotTableRenderer(data, opts)).heatmap("rowheatmap", opts)
        "Col Heatmap":    (data, opts) -> $(pivotTableRenderer(data, opts)).heatmap("colheatmap", opts)

    locales =
        en:
            aggregators: aggregators
            renderers: renderers
            localeStrings:
                renderError: "An error occurred rendering the PivotTable results."
                computeError: "An error occurred computing the PivotTable results."
                uiRenderError: "An error occurred rendering the PivotTable UI."
                selectAll: "Select All"
                selectNone: "Select None"
                tooMany: "(too many to list)"
                filterResults: "Filter values"
                apply: "Apply"
                cancel: "Cancel"
                totals: "Totals" #for table renderer
                vs: "vs" #for gchart renderer
                by: "by" #for gchart renderer

    #dateFormat deriver l10n requires month and day names to be passed in directly
    mthNamesEn = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
    dayNamesEn = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
    zeroPad = (number) -> ("0"+number).substr(-2,2)

    derivers =
        bin: (col, binWidth) -> (record) -> record[col] - record[col] % binWidth
        dateFormat: (col, formatString, utcOutput=false, mthNames=mthNamesEn, dayNames=dayNamesEn) ->
            utc = if utcOutput then "UTC" else ""
            (record) -> #thanks http://stackoverflow.com/a/12213072/112871
                date = new Date(Date.parse(record[col]))
                if isNaN(date) then return ""
                formatString.replace /%(.)/g, (m, p) ->
                    switch p
                        when "y" then date["get#{utc}FullYear"]()
                        when "m" then zeroPad(date["get#{utc}Month"]()+1)
                        when "n" then mthNames[date["get#{utc}Month"]()]
                        when "d" then zeroPad(date["get#{utc}Date"]())
                        when "w" then dayNames[date["get#{utc}Day"]()]
                        when "x" then date["get#{utc}Day"]()
                        when "H" then zeroPad(date["get#{utc}Hours"]())
                        when "M" then zeroPad(date["get#{utc}Minutes"]())
                        when "S" then zeroPad(date["get#{utc}Seconds"]())
                        else "%" + p

    rx = /(\d+)|(\D+)/g
    rd = /\d/
    rz = /^0/
    naturalSort = (as, bs) =>
        #nulls first
        return -1 if bs? and not as?
        return  1 if as? and not bs?

        #then raw NaNs
        return -1 if typeof as == "number" and isNaN(as)
        return  1 if typeof bs == "number" and isNaN(bs)

        #numbers and numbery strings group together
        nas = +as
        nbs = +bs
        return -1 if nas < nbs
        return  1 if nas > nbs

        #within that, true numbers before numbery strings
        return -1 if typeof as == "number" and typeof bs != "number"
        return  1 if typeof bs == "number" and typeof as != "number"
        return  0 if typeof as == "number" and typeof bs == "number"

        # 'Infinity' is a textual number, so less than 'A'
        return -1 if isNaN(nbs) and not isNaN(nas)
        return  1 if isNaN(nas) and not isNaN(nbs)

        #finally, "smart" string sorting per http://stackoverflow.com/a/4373421/112871
        a = String(as)
        b = String(bs)
        return 0 if a == b
        return (if a > b then 1 else -1) unless rd.test(a) and rd.test(b)

        #special treatment for strings containing digits
        a = a.match(rx) #create digits vs non-digit chunks and iterate through
        b = b.match(rx)
        while a.length and b.length
            a1 = a.shift()
            b1 = b.shift()
            if a1 != b1
                if rd.test(a1) and rd.test(b1) #both are digit chunks
                    return a1.replace(rz, ".0") - b1.replace(rz, ".0")
                else
                    return (if a1 > b1 then 1 else -1)
        return a.length - b.length

    sortAs = (order) ->
        mapping = {}
        l_mapping = {} # sort lowercased keys similarly
        for i, x of order
            mapping[x] = i
            l_mapping[x.toLowerCase()] = i if typeof x == "string"
        (a, b) ->
            if mapping[a]? and mapping[b]? then mapping[a] - mapping[b]
            else if mapping[a]? then -1
            else if mapping[b]? then 1
            else if l_mapping[a]? and l_mapping[b]? then l_mapping[a] - l_mapping[b]
            else if l_mapping[a]? then -1
            else if l_mapping[b]? then 1
            else naturalSort(a,b)

    getSort = (sorters, attr) ->
        if sorters?
            if $.isFunction(sorters)
                sort = sorters(attr)
                return sort if $.isFunction(sort)
            else if sorters[attr]?
                return sorters[attr]
        return naturalSort

    ###
    Data Model class
    ###

    class PivotData
        constructor: (input, opts = {}) ->
            @input = input
            @aggregator = opts.aggregator ? aggregatorTemplates.count()()
            @aggregatorName = opts.aggregatorName ? "Count"
            @colAttrs = opts.cols ? []
            @rowAttrs = opts.rows ? []
            @valAttrs = opts.vals ? []
            @sorters = opts.sorters ? {}
            @rowOrder = opts.rowOrder ? "key_a_to_z"
            @colOrder = opts.colOrder ? "key_a_to_z"
            @derivedAttributes = opts.derivedAttributes ? {}
            @filter = opts.filter ? (-> true)
            @tree = {}
            @rowKeys = []
            @colKeys = []
            @rowTotals = {}
            @colTotals = {}
            @allTotal = @aggregator(this, [], [])
            @sorted = false

            # iterate through input, accumulating data for cells
            PivotData.forEachRecord @input, @derivedAttributes, (record) =>
                @processRecord(record) if @filter(record)

        #can handle arrays or jQuery selections of tables
        @forEachRecord = (input, derivedAttributes, f) ->
            if $.isEmptyObject derivedAttributes
                addRecord = f
            else
                addRecord = (record) ->
                    record[k] = v(record) ? record[k] for k, v of derivedAttributes
                    f(record)

            #if it's a function, have it call us back
            if $.isFunction(input)
                input(addRecord)
            else if $.isArray(input)
                if $.isArray(input[0]) #array of arrays
                    for own i, compactRecord of input when i > 0
                        record = {}
                        record[k] = compactRecord[j] for own j, k of input[0]
                        addRecord(record)
                else #array of objects
                    addRecord(record) for record in input
            else if input instanceof $
                tblCols = []
                $("thead > tr > th", input).each (i) -> tblCols.push $(this).text()
                $("tbody > tr", input).each (i) ->
                    record = {}
                    $("td", this).each (j) -> record[tblCols[j]] = $(this).text()
                    addRecord(record)
            else
                throw new Error("unknown input format")

        forEachMatchingRecord: (criteria, callback) ->
            PivotData.forEachRecord @input, @derivedAttributes, (record) =>
                return if not @filter(record)
                for k, v of criteria
                    return if v != (record[k] ? "null")
                callback(record)

        arrSort: (attrs) =>
            sortersArr = (getSort(@sorters, a) for a in attrs)
            (a,b) ->
                for own i, sorter of sortersArr
                    comparison = sorter(a[i], b[i])
                    return comparison if comparison != 0
                return 0

        sortKeys: () =>
            if not @sorted
                @sorted = true
                v = (r,c) => @getAggregator(r,c).value()
                switch @rowOrder
                    when "value_a_to_z"  then @rowKeys.sort (a,b) =>  naturalSort v(a,[]), v(b,[])
                    when "value_z_to_a" then @rowKeys.sort (a,b) => -naturalSort v(a,[]), v(b,[])
                    else             @rowKeys.sort @arrSort(@rowAttrs)
                switch @colOrder
                    when "value_a_to_z"  then @colKeys.sort (a,b) =>  naturalSort v([],a), v([],b)
                    when "value_z_to_a" then @colKeys.sort (a,b) => -naturalSort v([],a), v([],b)
                    else             @colKeys.sort @arrSort(@colAttrs)

        getColKeys: () =>
            @sortKeys()
            return @colKeys

        getRowKeys: () =>
            @sortKeys()
            return @rowKeys

        processRecord: (record) -> #this code is called in a tight loop
            colKey = []
            rowKey = []
            colKey.push record[x] ? "null" for x in @colAttrs
            rowKey.push record[x] ? "null" for x in @rowAttrs
            flatRowKey = rowKey.join(String.fromCharCode(0))
            flatColKey = colKey.join(String.fromCharCode(0))

            @allTotal.push record

            if rowKey.length != 0
                if not @rowTotals[flatRowKey]
                    @rowKeys.push rowKey
                    @rowTotals[flatRowKey] = @aggregator(this, rowKey, [])
                @rowTotals[flatRowKey].push record

            if colKey.length != 0
                if not @colTotals[flatColKey]
                    @colKeys.push colKey
                    @colTotals[flatColKey] = @aggregator(this, [], colKey)
                @colTotals[flatColKey].push record

            if colKey.length != 0 and rowKey.length != 0
                if not @tree[flatRowKey]
                    @tree[flatRowKey] = {}
                if not @tree[flatRowKey][flatColKey]
                    @tree[flatRowKey][flatColKey] = @aggregator(this, rowKey, colKey)
                @tree[flatRowKey][flatColKey].push record

        getAggregator: (rowKey, colKey) =>
            flatRowKey = rowKey.join(String.fromCharCode(0))
            flatColKey = colKey.join(String.fromCharCode(0))
            if rowKey.length == 0 and colKey.length == 0
                agg = @allTotal
            else if rowKey.length == 0
                agg = @colTotals[flatColKey]
            else if colKey.length == 0
                agg = @rowTotals[flatRowKey]
            else
                agg = @tree[flatRowKey][flatColKey]
            return agg ? {value: (-> null), format: -> ""}

    #expose these to the outside world
    $.pivotUtilities = {aggregatorTemplates, aggregators, renderers, derivers, locales,
        naturalSort, numberFormat, sortAs, PivotData}

    ###
    Default Renderer for hierarchical table layout
    ###

    pivotTableRenderer = (pivotData, opts) ->

        defaults =
            table:
                clickCallback: null
                rowTotals: true
                colTotals: true
            localeStrings: totals: "Totals"

        opts = $.extend(true, {}, defaults, opts)

        colAttrs = pivotData.colAttrs
        rowAttrs = pivotData.rowAttrs
        rowKeys = pivotData.getRowKeys()
        colKeys = pivotData.getColKeys()

        if opts.table.clickCallback
            getClickHandler = (value, rowValues, colValues) ->
                filters = {}
                filters[attr] = colValues[i] for own i, attr of colAttrs when colValues[i]?
                filters[attr] = rowValues[i] for own i, attr of rowAttrs when rowValues[i]?
                return (e) -> opts.table.clickCallback(e, value, filters, pivotData)

        #now actually build the output
        result = document.createElement("table")
        result.className = "pvtTable"

        #helper function for setting row/col-span in pivotTableRenderer
        spanSize = (arr, i, j) ->
            if i != 0
                noDraw = true
                for x in [0..j]
                    if arr[i-1][x] != arr[i][x]
                        noDraw = false
                if noDraw
                  return -1 #do not draw cell
            len = 0
            while i+len < arr.length
                stop = false
                for x in [0..j]
                    stop = true if arr[i][x] != arr[i+len][x]
                break if stop
                len++
            return len

        #the first few rows are for col headers
        thead = document.createElement("thead")
        for own j, c of colAttrs
            tr = document.createElement("tr")
            if parseInt(j) == 0 and rowAttrs.length != 0
                th = document.createElement("th")
                th.setAttribute("colspan", rowAttrs.length)
                th.setAttribute("rowspan", colAttrs.length)
                tr.appendChild th
            th = document.createElement("th")
            th.className = "pvtAxisLabel"
            th.textContent = opts.labels[c] ? c
            tr.appendChild th
            for own i, colKey of colKeys
                x = spanSize(colKeys, parseInt(i), parseInt(j))
                if x != -1
                    th = document.createElement("th")
                    th.className = "pvtColLabel"
                    th.textContent = colKey[j]
                    th.setAttribute("colspan", x)
                    if parseInt(j) == colAttrs.length-1 and rowAttrs.length != 0
                        th.setAttribute("rowspan", 2)
                    tr.appendChild th
            if parseInt(j) == 0 && opts.table.rowTotals
                th = document.createElement("th")
                th.className = "pvtTotalLabel pvtRowTotalLabel"
                th.innerHTML = opts.localeStrings.totals
                th.setAttribute("rowspan", colAttrs.length + (if rowAttrs.length ==0 then 0 else 1))
                tr.appendChild th
            thead.appendChild tr

        #then a row for row header headers
        if rowAttrs.length !=0
            tr = document.createElement("tr")
            for own i, r of rowAttrs
                th = document.createElement("th")
                th.className = "pvtAxisLabel"
                th.textContent = opts.labels[r] ? r
                tr.appendChild th
            th = document.createElement("th")
            if colAttrs.length ==0
                th.className = "pvtTotalLabel pvtRowTotalLabel"
                th.innerHTML = opts.localeStrings.totals
            tr.appendChild th
            thead.appendChild tr
        result.appendChild thead

        #now the actual data rows, with their row headers and totals
        tbody = document.createElement("tbody")
        for own i, rowKey of rowKeys
            tr = document.createElement("tr")
            for own j, txt of rowKey
                x = spanSize(rowKeys, parseInt(i), parseInt(j))
                if x != -1
                    th = document.createElement("th")
                    th.className = "pvtRowLabel"
                    th.textContent = txt
                    th.setAttribute("rowspan", x)
                    if parseInt(j) == rowAttrs.length-1 and colAttrs.length !=0
                        th.setAttribute("colspan",2)
                    tr.appendChild th
            for own j, colKey of colKeys #this is the tight loop
                aggregator = pivotData.getAggregator(rowKey, colKey)
                val = aggregator.value()
                td = document.createElement("td")
                td.className = "pvtVal row#{i} col#{j}"
                td.textContent = aggregator.format(val)
                td.setAttribute("data-value", val)
                if getClickHandler?
                    td.onclick = getClickHandler(val, rowKey, colKey)
                tr.appendChild td

            if opts.table.rowTotals || colAttrs.length == 0
                totalAggregator = pivotData.getAggregator(rowKey, [])
                val = totalAggregator.value()
                td = document.createElement("td")
                td.className = "pvtTotal rowTotal"
                td.textContent = totalAggregator.format(val)
                td.setAttribute("data-value", val)
                if getClickHandler?
                    td.onclick = getClickHandler(val, rowKey, [])
                td.setAttribute("data-for", "row"+i)
                tr.appendChild td
            tbody.appendChild tr

        #finally, the row for col totals, and a grand total
        if opts.table.colTotals || rowAttrs.length == 0
            tr = document.createElement("tr")
            if opts.table.colTotals || rowAttrs.length == 0
                th = document.createElement("th")
                th.className = "pvtTotalLabel pvtColTotalLabel"
                th.innerHTML = opts.localeStrings.totals
                th.setAttribute("colspan", rowAttrs.length + (if colAttrs.length == 0 then 0 else 1))
                tr.appendChild th
            for own j, colKey of colKeys
                totalAggregator = pivotData.getAggregator([], colKey)
                val = totalAggregator.value()
                td = document.createElement("td")
                td.className = "pvtTotal colTotal"
                td.textContent = totalAggregator.format(val)
                td.setAttribute("data-value", val)
                if getClickHandler?
                    td.onclick = getClickHandler(val, [], colKey)
                td.setAttribute("data-for", "col"+j)
                tr.appendChild td
            if opts.table.rowTotals || colAttrs.length == 0
                totalAggregator = pivotData.getAggregator([], [])
                val = totalAggregator.value()
                td = document.createElement("td")
                td.className = "pvtGrandTotal"
                td.textContent = totalAggregator.format(val)
                td.setAttribute("data-value", val)
                if getClickHandler?
                    td.onclick = getClickHandler(val, [], [])
                tr.appendChild td
            tbody.appendChild tr
        result.appendChild tbody

        #squirrel this away for later
        result.setAttribute("data-numrows", rowKeys.length)
        result.setAttribute("data-numcols", colKeys.length)

        return result

    ###
    Pivot Table core: create PivotData object and call Renderer on it
    ###

    $.fn.pivot = (input, inputOpts, locale="en") ->
        locale = "en" if not locales[locale]?
        defaults =
            cols : [], rows: [], vals: []
            rowOrder: "key_a_to_z", colOrder: "key_a_to_z"
            dataClass: PivotData
            filter: -> true
            aggregator: aggregatorTemplates.count()()
            aggregatorName: "Count"
            sorters: {}
            labels: {}
            derivedAttributes: {}
            renderer: pivotTableRenderer

        localeStrings = $.extend(true, {}, locales.en.localeStrings, locales[locale].localeStrings)
        localeDefaults =
            rendererOptions: {
                localeSettings: localeStrings,
                labels: inputOpts.labels ? {}
            }
            localeStrings: localeStrings

        opts = $.extend(true, {}, localeDefaults, $.extend({}, defaults, inputOpts))

        result = null
        try
            pivotData = new opts.dataClass(input, opts)
            try
                result = opts.renderer(pivotData, opts.rendererOptions)
            catch e
                console.error(e.stack) if console?
                result = $("<span>").html opts.localeStrings.renderError
        catch e
            console.error(e.stack) if console?
            result = $("<span>").html opts.localeStrings.computeError

        x = this[0]
        x.removeChild(x.lastChild) while x.hasChildNodes()

        return result


    ###
    Pivot Table UI: calls Pivot Table core above with options set by user
    ###

    $.fn.pivotUI = (input, inputOpts, overwrite = false, locale="en") ->
        locale = "en" if not locales[locale]?
        defaults =
            derivedAttributes: {}
            aggregators: locales[locale].aggregators
            renderers: locales[locale].renderers
            hiddenAttributes: []
            hiddenFromAggregators: []
            hiddenFromDragDrop: []
            menuLimit: 500
            cols: [], rows: [], vals: []
            rowOrder: "key_a_to_z", colOrder: "key_a_to_z"
            dataClass: PivotData
            exclusions: {}
            inclusions: {}
            unusedAttrsVertical: 85
            autoSortUnusedAttrs: false
            onRefresh: null
            showUI: true
            labels: {}
            controls: {
                unused: false
                rules: false
            }
            filter: -> true
            sorters: {}

        localeStrings = $.extend(true, {}, locales.en.localeStrings, locales[locale].localeStrings)
        localeDefaults =
            rendererOptions: {localeStrings}
            localeStrings: localeStrings

        existingOpts = @data "pivotUIOptions"
        if not existingOpts? or overwrite
            opts = $.extend(true, {}, localeDefaults, $.extend({}, defaults, inputOpts))
        else
            opts = existingOpts

        try
            # do a first pass on the data to cache a materialized copy of any
            # function-valued inputs and to compute dimension cardinalities
            attrValues = {}
            materializedInput = []
            recordsProcessed = 0
            PivotData.forEachRecord input, opts.derivedAttributes, (record) ->
                return unless opts.filter(record)
                materializedInput.push(record)
                for own attr of record
                    if not attrValues[attr]?
                        attrValues[attr] = {}
                        if recordsProcessed > 0
                            attrValues[attr]["null"] = recordsProcessed
                for attr of attrValues
                    value = record[attr] ? "null"
                    attrValues[attr][value] ?= 0
                    attrValues[attr][value]++
                recordsProcessed++

            #start building the output
            uiTable = $("<table>", class: "pvtUi").attr("cellpadding", 5)

            #renderer control
            rendererControl = $("<td>", colspan: "3", class: "pvtUiCell pvtUiControls")

            renderer = $("<select>")
                .addClass("pvtRenderer")
                .appendTo(rendererControl)
                .bind "change", -> refresh() #capture reference
            for own x of opts.renderers
                $("<option>").val(x).html(x).appendTo(renderer)


            #axis list, including the double-click menu
            unused = $("<td>", class: "pvtAxisContainer pvtUnused pvtUiCell")
            shownAttributes = (a for a of attrValues when a not in opts.hiddenAttributes)
            shownInAggregators = (c for c in shownAttributes when c not in opts.hiddenFromAggregators)
            shownInDragDrop = (c for c in shownAttributes when c not in opts.hiddenFromDragDrop)

            unusedAttrsVerticalAutoOverride = true

            if opts.unusedAttrsVertical == true or unusedAttrsVerticalAutoOverride
                unused.addClass('pvtVertList')
            else
                unused.addClass('pvtHorizList')

            for own i, attr of shownInDragDrop
                do (attr) ->
                    values = (v for v of attrValues[attr])
                    hasExcludedItem = false
                    valueList = $("<div>", class: "pvtFilterBox panel panel-default").hide()
                    valueHeading = $("<div>", class: "panel-heading")
                    valueBody = $("<div>", class: "panel-body")
                    valueFooter = $("<div>", class: "panel-footer")

                    valueList.append valueHeading
                    valueList.append valueBody
                    valueList.append valueFooter

                    valueHeading.append $("<h4>", class: "panel-title").append(
                        $("<span>").text(opts.labels[attr] ? attr),
                        $("<span>").addClass("count").text("(#{values.length})"),
                    )

                    if values.length > opts.menuLimit
                        valueList.append $("<p>").html(opts.localeStrings.tooMany)
                    else
                        if values.length > 5
                            controls = $("<div>", class: "input-group").appendTo(valueBody)
                            sorter = getSort(opts.sorters, attr)
                            placeholder = opts.localeStrings.filterResults
                            $("<input>").appendTo(controls)
                                .attr({placeholder: placeholder, class: "pvtSearch form-control input-sm", type: "text"})
                                .bind "keyup", ->
                                    filter = $(this).val().toLowerCase().trim()
                                    accept_gen = (prefix, accepted) -> (v) ->
                                        real_filter = filter.substring(prefix.length).trim()
                                        return true if real_filter.length == 0
                                        return Math.sign(sorter(v.toLowerCase(), real_filter)) in accepted
                                    accept =
                                        if      filter.indexOf(">=") == 0 then accept_gen(">=", [1,0])
                                        else if filter.indexOf("<=") == 0 then accept_gen("<=", [-1,0])
                                        else if filter.indexOf(">") == 0  then accept_gen(">",  [1])
                                        else if filter.indexOf("<") == 0  then accept_gen("<",  [-1])
                                        else if filter.indexOf("~") == 0  then (v) ->
                                                return true if filter.substring(1).trim().length == 0
                                                v.toLowerCase().match(filter.substring(1))
                                        else (v) -> v.toLowerCase().indexOf(filter) != -1

                                    valueList.find('.pvtCheckContainer label span.value').each ->
                                        if accept($(this).text())
                                            $(this).parent().parent().addClass('pvtFilterIn').show()
                                        else
                                            $(this).parent().parent().removeClass("pvtFilterIn").hide()
                            controlsButtons = $("<span>", class: "input-group-btn").appendTo(controls)
                            $("<button>", type: "button", class: "btn btn-default btn-sm", title: opts.localeStrings.selectAll).appendTo(controlsButtons)
                                .append($("<i>", class: "far fa-fw fa-check-square"))
                                .bind "click", ->
                                    valueList.find("input:visible:not(:checked)")
                                        .prop("checked", true).toggleClass("changed")
                                    return false
                            $("<button>", type:"button", class: "btn btn-default btn-sm", title: opts.localeStrings.selectNone).appendTo(controlsButtons)
                                .append($("<i>", class: "far fa-fw fa-square"))
                                .bind "click", ->
                                    valueList.find("input:visible:checked")
                                        .prop("checked", false).toggleClass("changed")
                                    return false

                        checkContainer = $("<div>", class: "pvtCheckContainer").appendTo(valueBody)

                        for value in values.sort(getSort(opts.sorters, attr))
                             valueCount = attrValues[attr][value]
                             filterItem = $("<label>")
                             filterItemExcluded = false
                             if opts.inclusions[attr]
                                filterItemExcluded = (value not in opts.inclusions[attr])
                             else if opts.exclusions[attr]
                                filterItemExcluded = (value in opts.exclusions[attr])
                             hasExcludedItem ||= filterItemExcluded
                             $("<input>")
                                .attr("type", "checkbox").addClass('pvtFilter')
                                .attr("checked", !filterItemExcluded).data("filter", [attr,value])
                                .appendTo(filterItem)
                                .bind "change", -> $(this).toggleClass("changed")
                             filterItem.append $("<span>").addClass("value").text(value)
                             filterItem.append $("<span>").addClass("count").text("("+valueCount+")")
                             checkContainer.append $("<div>", class: "checkbox").append(filterItem)

                    closeFilterBox = ->
                        if valueList.find("[type='checkbox']").length >
                               valueList.find("[type='checkbox']:checked").length
                                attrElem.addClass "pvtFilteredAttribute"
                            else
                                attrElem.removeClass "pvtFilteredAttribute"

                            valueList.find('.pvtSearch').val('')
                            valueList.find('.pvtCheckContainer div.checkbox').show()
                            valueList.hide()

                    finalButtons = $("<div>", class: "text-right").appendTo(valueFooter)

                    if values.length <= opts.menuLimit
                        $("<button>", type: "button", class: "btn btn-default btn-sm").text(opts.localeStrings.apply)
                            .appendTo(finalButtons).bind "click", ->
                                if valueList.find(".changed").removeClass("changed").length
                                    refresh()
                                closeFilterBox()
                        $("<span>").html('&nbsp;').appendTo(finalButtons)

                    $("<button>", type: "button", class: "btn btn-default btn-sm").text(opts.localeStrings.cancel)
                        .appendTo(finalButtons).bind "click", ->
                            valueList.find(".changed:checked")
                                .removeClass("changed").prop("checked", false)
                            valueList.find(".changed:not(:checked)")
                                .removeClass("changed").prop("checked", true)
                            closeFilterBox()

                    triangleLink = $("<i>", class: "fas fa-fw fa-caret-down").addClass('pvtTriangle')
                        .bind "click", (e) ->
                            UI = $(".pvtUi")
                            UIHeight = UI.height()
                            UIOffset = UI.offset()
                            targetOffset = $(e.currentTarget).offset()
                            valueListHeight = valueList.height()
                            space = UIHeight - (targetOffset.top - UIOffset.top)

                            if space > valueListHeight
                                top = targetOffset.top - UIOffset.top
                            else if space > valueListHeight / 2
                                top = targetOffset.top - UIOffset.top - valueListHeight / 2
                            else
                                top = targetOffset.top - UIOffset.top - valueListHeight
                                
                            $(".pvtFilterBox").hide()
                            valueList.css(left: targetOffset.left - UIOffset.left + 10, top: top + 10).show()

                    attrElem = $("<li>").addClass("axis_#{i}")
                        .append $("<span>").addClass('label label-default pvtAttr').attr("title", opts.labels[attr] ? attr).text(opts.labels[attr] ? attr).data("attrName", attr).append(triangleLink)

                    attrElem.addClass('pvtFilteredAttribute') if hasExcludedItem
                    unused.append(attrElem)
                    rendererControl.append(valueList)

            tr0 = $("<tr>").appendTo(uiTable)
            tr1 = $("<tr>").appendTo(uiTable)

            #aggregator menu and value area

            aggregator = $("<select>").addClass('pvtAggregator')
                .bind "change", -> refresh() #capture reference
            for own x of opts.aggregators
                aggregator.append $("<option>").val(x).html(x)

            rendererControl
                .append(" ")
                .append(aggregator)

            ordering =
                key_a_to_z:   {rowSymbol: $("<i>", class: "far fa-fw fa-arrows-alt-v"),         colSymbol: $("<i>", class: "far fa-fw fa-arrows-alt-h"),         next: "value_a_to_z"}
                value_a_to_z: {rowSymbol: $("<i>", class: "far fa-fw fa-long-arrow-alt-down"),  colSymbol: $("<i>", class: "far fa-fw fa-long-arrow-alt-right"), next: "value_z_to_a"}
                value_z_to_a: {rowSymbol: $("<i>", class: "far fa-fw fa-long-arrow-alt-up"),    colSymbol: $("<i>", class: "far fa-fw fa-long-arrow-alt-left"),  next: "key_a_to_z"}

            rowOrderArrow = $("<button>", class: "btn btn-default btn-xs")#.addClass("pvtRowOrder")
                .data("order", opts.rowOrder).html(ordering[opts.rowOrder].rowSymbol)
                .bind "click", ->
                    $(this).data("order", ordering[$(this).data("order")].next)
                    $(this).html(ordering[$(this).data("order")].rowSymbol)
                    refresh()

            colOrderArrow = $("<button>", class: "btn btn-default btn-xs")#.addClass("pvtColOrder")
                .data("order", opts.colOrder).html(ordering[opts.colOrder].colSymbol)
                .bind "click", ->
                    $(this).data("order", ordering[$(this).data("order")].next)
                    $(this).html(ordering[$(this).data("order")].colSymbol)
                    refresh()

            orderGroup = $("<div>", class: "btn-group", role: "group")
                .append(rowOrderArrow)
                .append(colOrderArrow)

            unusedVisibility = $("<button>", class: "btn btn-default btn-xs")
                .append($("<i>", class: "far fa-fw fa-ruler-vertical fa-flip-horizontal"))
                .bind "click", ->
                    $(this).toggleClass('active')
                    $(".pvtUnused").toggle()
                    pvtVals = $(".pvtVals")
                    if pvtVals.attr("colspan") == "2"
                        pvtVals.attr("colspan", 1)
                    else
                        pvtVals.attr("colspan", 2)
            unusedVisibility.addClass("active") if opts.controls.unused
                        
            rulesVisibility = $("<button>", class: "btn btn-default btn-xs")
                .append($("<i>", class: "far fa-fw fa-ruler-combined fa-flip-vertical"))
                .bind "click", ->
                    $(this).toggleClass('active')
                    $(".pvtRows, .pvtCols").toggle()
            rulesVisibility.addClass("active") if opts.controls.rules

            panelsGroup = $("<div>", class: "btn-group", role: "group")
                .append(unusedVisibility)
                .append(rulesVisibility)

            controlsToolbar = $("<div>", class: "btn-toolbar")
                .append(panelsGroup)
                .append(orderGroup)

            $("<td>", class: "pvtVals pvtUiCell")
              .appendTo(tr1)
              .append(controlsToolbar)

            #column axes
            $("<td>").addClass('pvtAxisContainer pvtHorizList pvtCols pvtUiCell').appendTo(tr1)

            #row axes
            tr2 = $("<tr>").appendTo(uiTable)
            tr2.append $("<td>").addClass('pvtAxisContainer pvtRows pvtUiCell').attr("valign", "top")

            #the actual pivot table container
            pivotTable = $("<td>")
                .attr("valign", "top")
                .addClass('pvtRendererArea')
                .appendTo(tr2)

            #finally the renderer dropdown and unused attribs are inserted at the requested location
            if opts.unusedAttrsVertical == true or unusedAttrsVerticalAutoOverride
                uiTable.find('tr:nth-child(1)').prepend rendererControl
                uiTable.find('tr:nth-child(3)').prepend unused
            else
                uiTable.prepend $("<tr>").append(rendererControl).append(unused)

            #render the UI in its default state
            visible = $("<div>", class: "pvtVisible")
            responsive = $("<div>", class: "pvtResponsive").appendTo(visible)
            uiTable.appendTo(responsive)
            
            @html visible

            $(".pvtRows, .pvtCols").hide() if !opts.controls.rules
            $(".pvtUnused").hide() if !opts.controls.unused
            $(".pvtVals").attr("colspan", 2) if opts.controls.unused

            #set up the UI initial state as requested by moving elements around

            for x in opts.cols
                @find(".pvtCols").append @find(".axis_#{$.inArray(x, shownInDragDrop)}")
            for x in opts.rows
                @find(".pvtRows").append @find(".axis_#{$.inArray(x, shownInDragDrop)}")
            if opts.aggregatorName?
                @find(".pvtAggregator").val opts.aggregatorName
            if opts.rendererName?
                @find(".pvtRenderer").val opts.rendererName

            @find(".pvtUiCell").hide() unless opts.showUI

            initialRender = true

            #set up for refreshing
            refreshDelayed = (first) =>
                subopts =
                    derivedAttributes: opts.derivedAttributes
                    localeStrings: opts.localeStrings
                    rendererOptions: opts.rendererOptions
                    sorters: opts.sorters
                    labels: opts.labels
                    cols: [], rows: []
                    dataClass: opts.dataClass

                numInputsToProcess = opts.aggregators[aggregator.val()]([])().numInputs ? 0
                vals = []
                @find(".pvtRows li span.pvtAttr").each -> subopts.rows.push $(this).data("attrName")
                @find(".pvtCols li span.pvtAttr").each -> subopts.cols.push $(this).data("attrName")
                @find(".pvtUiControls select.pvtAttrDropdown").each ->
                    if numInputsToProcess == 0
                        $(this).prev(".pvtAttrDropdownBy").remove()
                        $(this).remove()
                    else
                        numInputsToProcess--
                        vals.push $(this).val() if $(this).val() != ""

                if numInputsToProcess != 0
                    pvtUiCell = @find(".pvtUiControls")
                    for x in [0...numInputsToProcess]
                        newDropdown = $("<select>")
                            .addClass('pvtAttrDropdown')
                            .append($("<option>"))
                            .bind "change", -> refresh()
                        for attr in shownInAggregators
                            newDropdown.append($("<option>").val(attr).text(opts.labels[attr] ? attr))
                        pvtUiCell
                            .append(" ")
                            .append($("<span>", class: "pvtAttrDropdownBy").text(localeStrings.by))
                            .append(" ")
                            .append(newDropdown)

                if initialRender
                    vals = opts.vals
                    i = 0
                    @find(".pvtUiControls select.pvtAttrDropdown").each ->
                        $(this).val vals[i]
                        i++
                    initialRender = false

                subopts.aggregatorName = aggregator.val()
                subopts.vals = vals
                subopts.aggregator = opts.aggregators[aggregator.val()](vals)
                subopts.renderer = opts.renderers[renderer.val()]
                subopts.rowOrder = rowOrderArrow.data("order")
                subopts.colOrder = colOrderArrow.data("order")
                #construct filter here
                exclusions = {}
                @find('input.pvtFilter').not(':checked').each ->
                    filter = $(this).data("filter")
                    if exclusions[filter[0]]?
                        exclusions[filter[0]].push( filter[1] )
                    else
                        exclusions[filter[0]] = [ filter[1] ]
                #include inclusions when exclusions present
                inclusions = {}
                @find('input.pvtFilter:checked').each ->
                    filter = $(this).data("filter")
                    if exclusions[filter[0]]?
                        if inclusions[filter[0]]?
                            inclusions[filter[0]].push( filter[1] )
                        else
                            inclusions[filter[0]] = [ filter[1] ]

                subopts.filter = (record) ->
                    return false if not opts.filter(record)
                    for k,excludedItems of exclusions
                        return false if ""+(record[k] ? 'null') in excludedItems
                    return true

                if (["Line Chart", "Bar Chart", "Stacked Bar Chart", "Area Chart", "Scatter Chart", "Pie Chart"].indexOf(renderer.val()) > -1)
                    {result, wrapper} = pivotTable.pivot(materializedInput, subopts);
                    pivotTable.append(result)
                    wrapper.draw(result[0])
                else
                    pivotTable.append(pivotTable.pivot(materializedInput, subopts));


                pivotUIOptions = $.extend {}, opts,
                    cols: subopts.cols
                    rows: subopts.rows
                    colOrder: subopts.colOrder
                    rowOrder: subopts.rowOrder
                    vals: vals
                    exclusions: exclusions
                    inclusions: inclusions
                    inclusionsInfo: inclusions #duplicated for backwards-compatibility
                    aggregatorName: aggregator.val()
                    rendererName: renderer.val()

                @data "pivotUIOptions", pivotUIOptions

                # if requested make sure unused columns are in alphabetical order
                if opts.autoSortUnusedAttrs
                    unusedAttrsContainer = @find("td.pvtUnused.pvtAxisContainer")
                    $(unusedAttrsContainer).children("li")
                        .sort((a, b) => naturalSort($(a).text(), $(b).text()))
                        .appendTo unusedAttrsContainer

                pivotTable.css("opacity", 1)
                opts.onRefresh(pivotUIOptions) if opts.onRefresh? and !first?

            refresh = (first) =>
                pivotTable.css("opacity", 0.5)
                setTimeout ( -> refreshDelayed first), 10

            #the very first refresh will actually display the table
            refresh(true)

            @find(".pvtAxisContainer").sortable
                    update: (e, ui) -> refresh() if not ui.sender?
                    connectWith: @find(".pvtAxisContainer")
                    items: 'li'
                    placeholder: 'pvtPlaceholder'

            # $(".pvtUi .pvtRows, .pvtUi .pvtUnused").resizable({
            #     handles: "e",
            #     resize: (event, ui) ->
            #         if ui.size.width > 150
            #             event.target.style.maxWidth = ui.size.width + 'px'
            # })
        catch e
            console.error(e.stack) if console?
            @html opts.localeStrings.uiRenderError
        return this

    ###
    Heatmap post-processing
    ###

    $.fn.heatmap = (scope = "heatmap", opts) ->
        numRows = @data "numrows"
        numCols = @data "numcols"

        # given a series of values
        # must return a function to map a given value to a CSS color
        colorScaleGenerator = opts?.heatmap?.colorScaleGenerator
        colorScaleGenerator ?= (values) ->
            min = Math.min(values...)
            max = Math.max(values...)
            return (x) ->
                nonRed = 255 - Math.round 255*(x-min)/(max-min)
                return "rgb(255,#{nonRed},#{nonRed})"

        heatmapper = (scope) =>
            forEachCell = (f) =>
                @find(scope).each ->
                    x = $(this).data("value")
                    f(x, $(this)) if x? and isFinite(x)

            values = []
            forEachCell (x) -> values.push x
            colorScale = colorScaleGenerator(values)
            forEachCell (x, elem) -> elem.css "background-color", colorScale(x)

        switch scope
            when "heatmap"    then heatmapper ".pvtVal"
            when "rowheatmap" then heatmapper ".pvtVal.row#{i}" for i in [0...numRows]
            when "colheatmap" then heatmapper ".pvtVal.col#{j}" for j in [0...numCols]

        heatmapper ".pvtTotal.rowTotal"
        heatmapper ".pvtTotal.colTotal"

        return this

    ###
    Barchart post-processing
    ###

    $.fn.barchart = (opts) ->
        numRows = @data "numrows"
        numCols = @data "numcols"

        barcharter = (scope) =>
            forEachCell = (f) =>
                @find(scope).each ->
                    x = $(this).data("value")
                    f(x, $(this)) if x? and isFinite(x)

            values = []
            forEachCell (x) -> values.push x
            max = Math.max(values...)
            if max < 0
                max = 0
            range = max;
            min = Math.min(values...)
            if min < 0
                range = max - min
            scaler = (x) -> 100*x/(1.4*range)
            forEachCell (x, elem) ->
                text = elem.text()
                wrapper = $("<div>").css
                    "position": "relative"
                    "height": "55px"
                bgColor = "gray"
                bBase = 0
                if min < 0
                    bBase = scaler(-min)
                if x < 0
                    bBase += scaler(x)
                    bgColor = "darkred"
                    x = -x
                wrapper.append $("<div>").css
                    "position": "absolute"
                    "bottom": bBase + "%"
                    "left": 0
                    "right": 0
                    "height": scaler(x) + "%"
                    "background-color": bgColor
                wrapper.append $("<div>").text(text).css
                    "position":"relative"
                    "padding-left":"5px"
                    "padding-right":"5px"

                elem.css("padding": 0,"padding-top": "5px", "text-align": "center").html wrapper

        barcharter ".pvtVal.row#{i}" for i in [0...numRows]
        barcharter ".pvtTotal.colTotal"

        return this
