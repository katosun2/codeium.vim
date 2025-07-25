" This file is heavily modified to use Ollama instead of the Codeium service.
 " All server management, download, and heartbeat logic has been removed.

function! s:NoopCallback(...) abort
endfunction

" This is the core function that sends a request to the Ollama API.
" It's a simplified version of the original `codeium#server#Request`.
function! codeium#server#Request(type, data, ...) abort
  " We only care about 'GetCompletions' requests. Ignore everything else.
  if a:type !=# 'GetCompletions'
    call codeium#log#Info('Ignoring request type: ' . a:type)
    return
  endif

  let ollama_api_url = get(g:, 'codeium_ollama_api_url', 'http://127.0.0.1:11434/api/generate')
  " let ollama_model = get(g:, 'codeium_ollama_model', 'codellama:7b')
  let ollama_model = get(g:, 'codeium_ollama_model', 'qwen2.5-coder:3b')
  let ollama_timeout = get(g:, 'codeium_ollama_timeout', 30) " Timeout in seconds, increased to 30s

  " --- Prompt Engineering ---
  " This part is crucial for getting good results from Ollama.
  " We'll use the Fill-in-the-Middle (FIM) format that Code Llama is trained on.
  " https://huggingface.co/blog/codellama#fill-in-the-middle
  " Format: <PRE>prefix<SUF>suffix<MID>
  let doc = get(a:data, 'document', {})
  let source = get(doc, 'text', '')
  let cursor_offset = get(doc, 'cursorOffset', 0)

  let prefix = strpart(source, 0, cursor_offset)
  let suffix = strpart(source, cursor_offset)

  " Allow disabling FIM for models that don't support it.
  let use_fim = get(g:, 'codeium_ollama_use_fim', v:true)
  if use_fim
    let prompt = '<PRE>' . prefix . '<SUF>' . suffix . '<MID>'
  else
    let prompt = prefix
  endif

  let request_body = {
        \ 'model': ollama_model,
        \ 'prompt': prompt,
        \ 'stream': v:false,
        \ }

  let data_json = json_encode(request_body)

  " Read data from stdin using '-d @-' to avoid command length limits on Windows.
  let args = [
            \ 'curl', '-s',
            \ '--max-time', ollama_timeout,
            \ ollama_api_url,
            \ '--header', 'Content-Type: application/json',
            \ '-d', '@-'
            \ ]

  call codeium#log#Info('--- Sending Ollama Request ---')
  call codeium#log#Info('Timeout set to: ' . ollama_timeout . 's')
  call codeium#log#Info('Args: ' . string(args))
  call codeium#log#Info('Data: ' . data_json)

  let result = {'out': [], 'err': []}
  let ExitCallback = a:0 && !empty(a:1) ? a:1 : function('s:NoopCallback')

  if has('nvim')
    let jobid = jobstart(args, {
                \ 'on_stdout': { _, data, __ -> extend(result.out, data) },
                \ 'on_stderr': { _, data, __ -> extend(result.err, data) },
                \ 'on_exit': { _, status, ___ -> s:OnOllamaExit(result, status, ExitCallback, a:data) },
                \ })
    call chansend(jobid, data_json)
    call chanclose(jobid, 'stdin')
    return jobid
  else
    let job = job_start(args, {
                \ 'in_mode': 'raw',
                \ 'out_cb': { _, data -> add(result.out, data) },
                \ 'err_cb': { _, data -> add(result.err, data) },
                \ 'exit_cb': { _, status -> s:OnOllamaExit(result, status, ExitCallback, a:data) },
                \ })
    let channel = job_getchannel(job)
    call ch_sendraw(channel, data_json)
    call ch_close_in(channel)
    return job
  endif
endfunction

" This function is called when the curl command to Ollama finishes.
" It transforms the Ollama response into the format the plugin expects.
function! s:OnOllamaExit(result, status, on_complete_cb, original_request_data) abort
  call codeium#log#Info('--- Received Ollama Response ---')
  call codeium#log#Info('Status: ' . a:status)
  if !empty(a:result.err)
    call codeium#log#Error('Stderr: ' . join(a:result.err, "\n"))
  endif

  if a:status != 0
    call codeium#log#Error('Ollama request failed. See stderr above.')
    return
  endif

  let response_text = join(a:result.out, "")
  call codeium#log#Info('Raw Response: ' . response_text)
  if empty(response_text)
    call codeium#log#Error('Ollama returned an empty response.')
    return
  endif

  try
    let ollama_response = json_decode(response_text)

    if get(ollama_response, 'done', v:false) == v:false
      call codeium#log#Error('Ollama response indicates an error or streaming is not complete.')
      call codeium#log#Error('Response: ' . response_text)
      return
    endif

    let completion_text = get(ollama_response, 'response', '')
    if empty(completion_text)
      call codeium#log#Info('Ollama returned a response with no completion text.')
      return
    endif

    " Now, we build the response structure that s:HandleCompletionsResult expects.
    " We need to provide precise context for the rendering function.
    let doc = get(a:original_request_data, 'document', {})
    let cursor_line_num = get(doc, 'line', 1) " 1-based line number
    let cursor_char_num = get(doc, 'character', 1) " 1-based character number
    let lines = split(get(doc, 'text', ''), "\n")
    let line_text = get(lines, cursor_line_num - 1, '')
    let line_prefix = strpart(line_text, 0, cursor_char_num - 1)

    let completion_id = 'ollama-' . localtime()
    let completion_item = {
          \ 'completion': {
          \   'text': completion_text,
          \   'completionId': completion_id
          \ },
          \ 'range': {
          \   'startOffset': get(doc, 'cursorOffset', 0),
          \   'endOffset': get(doc, 'cursorOffset', 0)
          \ },
          \ 'completionParts': [{
          \   'type': 'COMPLETION_PART_TYPE_INLINE',
          \   'text': completion_text,
          \   'line': cursor_line_num - 1, " Rendering function expects 0-based line
          \   'prefix': line_prefix
          \ }]
          \ }

    let plugin_response = {
          \ 'completionItems': [completion_item]
          \ }

    let response_for_plugin = [json_encode(plugin_response)]
    call codeium#log#Info('Transformed Response for Plugin: ' . string(response_for_plugin))

    " Call the original callback with the transformed data.
    call a:on_complete_cb(response_for_plugin, a:result.err, a:status)

  catch
    call codeium#log#Error('Failed to decode Ollama JSON response.')
    call codeium#log#Error('Response text: ' . response_text)
    call codeium#log#Exception()
  endtry
endfunction

" --- Empty functions to prevent errors from the rest of the plugin ---

function! codeium#server#Start(...) abort
  " No server to start. Do nothing.
  call codeium#log#Info('Using Ollama backend. No server to start.')
endfunction

function! codeium#server#RequestMetadata() abort
  " This data is not needed for Ollama, but other parts of the plugin might call it.
  return {}
endfunction
