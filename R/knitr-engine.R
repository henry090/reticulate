#' A reticulate Engine for Knitr
#'
#' This provides a `reticulate` engine for `knitr`, suitable for usage when
#' attempting to render Python chunks. Using this engine allows for shared state
#' between Python chunks in a document -- that is, variables defined by one
#' Python chunk can be used by later Python chunks.
#'
#' The engine can be activated by setting (for example)
#'
#' ```
#' knitr::knit_engines$set(python = reticulate::eng_python)
#' ```
#'
#' Typically, this will be set within a document's setup chunk, or by the
#' environment requesting that Python chunks be processed by this engine.
#' Note that `knitr` (since version 1.18) will use the `reticulate` engine by
#' default when executing Python chunks within an R Markdown document.
#'
#' @param options
#'   Chunk options, as provided by `knitr` during chunk execution.
#'
#' @export
eng_python <- function(options) {
  options <- eng_python_validate_options(options)

  # when 'eval = FALSE', we can just return the source code verbatim
  # (skip any other per-chunk work)
  if (identical(options$eval, FALSE)) {
    outputs <- list()
    if (!identical(options$echo, FALSE))
      outputs[[1]] <- structure(list(src = options$code), class = "source")
    wrap <- getOption("reticulate.engine.wrap", eng_python_wrap)
    return(wrap(outputs, options))
  }

  engine.path <- if (is.list(options[["engine.path"]]))
    options[["engine.path"]][["python"]]
  else
    options[["engine.path"]]

  # if the user has requested a custom Python, attempt
  # to honor that request (warn if Python already initialized
  # to a different version)
  if (is.character(engine.path)) {

    # if Python has not yet been loaded, then try
    # to load it with the requested version of Python
    if (!py_available())
      use_python(engine.path, required = TRUE)

    # double-check that we've loaded the requested Python
    conf <- py_config()
    requestedPython <- normalizePath(engine.path)
    actualPython <- normalizePath(conf$python)
    if (requestedPython != actualPython) {
      fmt <- "cannot honor request to use Python %s [%s already loaded]"
      msg <- sprintf(fmt, requestedPython, actualPython)
      warning(msg, immediate. = TRUE, call. = FALSE)
    }
  }

  context <- new.env(parent = emptyenv())
  eng_python_initialize(
    options,
    context = context,
    envir = environment()
  )

  # helper function for extracting range of code, dropping blank lines
  extract <- function(code, range) {
    snippet <- code[range[1]:range[2]]
    paste(snippet, collapse = "\n")
  }

  # extract the code to be run -- we'll attempt to run the code line by line
  # and detect changes so that we can interleave code and output (similar to
  # what one sees when executing an R chunk in knitr). to wit, we'll do our
  # best to emulate the return format of 'evaluate::evaluate()'
  code <- options$code
  n <- length(code)
  if (n == 0)
    return(list())

  # use 'ast.parse()' to parse Python code and collect line numbers, so we
  # can split source code into statements
  ast <- import("ast", convert = TRUE)
  pasted <- paste(code, collapse = "\n")
  parsed <- tryCatch(ast$parse(pasted, "<string>"), error = identity)
  if (inherits(parsed, "error")) {
    error <- reticulate::py_last_error()
    stop(error$value, call. = FALSE)
  }

  # iterate over top-level nodes and extract line numbers
  lines <- vapply(parsed$body, function(node) {
    if(py_has_attr(node, 'decorator_list') && length(node$decorator_list)) {
      node$decorator_list[[1]]$lineno
    } else {
      node$lineno
    }
  }, integer(1))

  # it's possible for multiple statements to live on the
  # same line (e.g. `print("a"); print("b")`) so only keep
  # uniques
  lines <- unique(lines)

  # convert from lines to ranges (be sure to handle the zero-length case)
  ranges <- list()
  if (length(lines)) {
    starts <- lines
    ends <- c(lines[-1] - 1, length(code))
    ranges <- mapply(c, starts, ends, SIMPLIFY = FALSE)
  }

  # line index from which source should be emitted
  pending_source_index <- 1

  # whether an error occurred during execution
  had_error <- FALSE

  # actual outputs to be returned to knitr
  outputs <- list()
  
  # 'held' outputs, to be appended at the end (for results = "hold")
  held_outputs <- list()

  # synchronize state R -> Python
  eng_python_synchronize_before()

  # determine if we should capture errors
  # (don't capture errors during knit)
  capture_errors <-
    identical(options$error, TRUE) ||
    identical(getOption("knitr.in.progress", default = FALSE), FALSE)

  for (i in seq_along(ranges)) {

    # extract range
    range <- ranges[[i]]

    # extract code to be run
    snippet <- extract(code, range)

    # save last value
    last_value <- py_last_value()

    # use trailing semicolon to suppress output of return value
    suppress <- grepl(";\\s*$", snippet)
    compile_mode <- if (suppress) "exec" else "single"

    # run code and capture output
    captured <- if (capture_errors)
      tryCatch(py_compile_eval(snippet, compile_mode), error = identity)
    else
      py_compile_eval(snippet, compile_mode)

    # handle matplotlib output
    captured <- eng_python_matplotlib_handle_output(captured, last_value, i == length(ranges))

    if (length(context$pending_plots) || !identical(captured, "")) {

      # append pending source to outputs (respecting 'echo' option)
      if (!identical(options$echo, FALSE) && !identical(options$results, "hold")) {
        extracted <- extract(code, c(pending_source_index, range[2]))
        output <- structure(list(src = extracted), class = "source")
        outputs[[length(outputs) + 1]] <- output
      }

      # append captured outputs (respecting 'include' option)
      if (isTRUE(options$include)) {

        if (identical(options$results, "hold")) {
          
          # append captured output
          if (!identical(captured, ""))
            held_outputs[[length(held_outputs) + 1]] <- captured
          
          # append captured images / figures
          for (plot in context$pending_plots)
            held_outputs[[length(held_outputs) + 1]] <- plot
          context$pending_plots <- list()
          
        } else {
          
          # append captured output
          if (!identical(captured, ""))
            outputs[[length(outputs) + 1]] <- captured
          
          # append captured images / figures
          for (plot in context$pending_plots)
            outputs[[length(outputs) + 1]] <- plot
          context$pending_plots <- list()
          
        }

      }

      # update pending source range
      pending_source_index <- range[2] + 1

      # bail if we had an error with 'error=FALSE'
      if (identical(options$error, FALSE) && inherits(captured, "error")) {
        had_error <- TRUE
        break
      }

    }
  }

  # if we have leftover input, add that now
  has_leftovers <-
    !had_error &&
    !identical(options$echo, FALSE) &&
    !identical(options$results, "hold") &&
    pending_source_index <= n
  
  if (has_leftovers) {
    leftover <- extract(code, c(pending_source_index, n))
    outputs[[length(outputs) + 1]] <- structure(
      list(src = leftover),
      class = "source"
    )
  }
  
  # if we were using held outputs, we just inject the source in now
  if (identical(options$results, "hold")) {
    output <- structure(list(src = code), class = "source")
    outputs[[length(outputs) + 1]] <- output
  }
  
  # if we had held outputs, add those in now (merging text output as appropriate)
  text_output <- character()
  
  for (i in seq_along(held_outputs)) {
    
    if (is.character(held_outputs[[i]])) {
      
      # merge text output and save for later
      text_output <- c(text_output, held_outputs[[i]])
      
    } else {
      
      # add in pending text output
      if (length(text_output)) {
        outputs[[length(outputs) + 1]] <- paste(text_output, collapse = "")
        text_output <- character()
      }
      
      # add in this piece of output
      outputs[[length(outputs) + 1]] <- held_outputs[[i]]
    }
  }
  
  # if we have any leftover held output, add in now
  if (length(text_output))
    outputs[[length(outputs) + 1]] <- paste(text_output, collapse = "")

  eng_python_synchronize_after()

  wrap <- getOption("reticulate.engine.wrap", eng_python_wrap)
  wrap(outputs, options)

}

eng_python_initialize <- function(options, context, envir) {

  if (is.character(options$engine.path))
    use_python(options$engine.path[[1]])

  ensure_python_initialized()

  eng_python_initialize_matplotlib(options, context, envir)
}

eng_python_matplotlib_show <- function(plt, options) {
  
  # we need to work in either base.dir or output.dir, depending
  # on which of the two has been requested by the user. (note
  # that output.dir should always be set)
  dir <-
    knitr::opts_knit$get("base.dir") %||%
    knitr::opts_knit$get("output.dir")

  # move to the requested directory
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  owd <- setwd(dir)
  on.exit(setwd(owd), add = TRUE)
  
  # construct plot path
  plot_counter <- yoink("knitr", "plot_counter")
  path <- knitr::fig_path(
    suffix = options$dev,
    options = options,
    number = plot_counter()
  )
  
  # save the current figure
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  plt$savefig(path, dpi = options$dpi)
  plt$clf()
  
  # include the requested path
  knitr::include_graphics(path)

}

eng_python_initialize_matplotlib <- function(options, context, envir) {

  if (!py_module_available("matplotlib"))
    return()

  # attempt to enforce a non-Qt matplotlib backend. this is especially important
  # with RStudio Desktop as attempting to use a Qt backend will cause issues due
  # to mismatched Qt versions between RStudio and Anaconda environments, and
  # will cause crashes when attempting to generate plots
  if (is_rstudio_desktop()) {

    matplotlib <- import("matplotlib", convert = TRUE)

    # check to see if a backend has already been initialized. if so, we
    # need to switch backends; otherwise, we can simply request to use a
    # specific one when the backend is initialized later
    sys <- import("sys", convert = FALSE)
    if ("matplotlib.backends" %in% names(sys$modules)) {
      matplotlib$pyplot$switch_backend("agg")
    } else {
      version <- numeric_version(matplotlib$`__version__`)
      if (version < "3.3.0")
        matplotlib$use("agg", warn = FALSE, force = TRUE)
      else
        matplotlib$use("agg", force = TRUE)
    }
  }

  # double-check that we can load 'pyplot' (this can fail if matplotlib
  # is installed but is initialized to a backend missing some required components)
  if (!py_module_available("matplotlib.pyplot"))
    return()

  # initialize pending_plots list
  context$pending_plots <- list()

  plt <- import("matplotlib.pyplot", convert = FALSE)

  # rudely steal 'plot_counter' (used by default 'show()' implementation below)
  # and then reset the counter when we're done
  plot_counter <- yoink("knitr", "plot_counter")
  defer(plot_counter(reset = TRUE), envir = envir)

  # save + restore old show hook
  show <- plt$show
  defer(plt$show <- show, envir = envir)
  plt$show <- function(...) {

    # call hook to generate plot
    hook <- getOption("reticulate.engine.matplotlib.show", eng_python_matplotlib_show)
    graphic <- hook(plt, options)

    # update set of pending plots
    context$pending_plots[[length(context$pending_plots) + 1]] <<- graphic

    # return None to ensure no printing of output here (just inclusion of
    # plot as a side effect)
    r_to_py(NULL)

  }

  # set up figure dimensions
  plt$rc("figure", figsize = tuple(options$fig.width, options$fig.height))

}

# synchronize objects R -> Python
eng_python_synchronize_before <- function() {
  py_inject_r()
}

# synchronize objects Python -> R
eng_python_synchronize_after <- function() {}

eng_python_wrap <- function(outputs, options) {
  # TODO: development version of knitr supplies new 'engine_output()'
  # interface -- use that when it's on CRAN
  # https://github.com/yihui/knitr/commit/71bfd8796d485ed7bb9db0920acdf02464b3df9a
  wrap <- yoink("knitr", "wrap")
  wrap(outputs, options)
}

eng_python_validate_options <- function(options) {

  # warn about unsupported numeric options and convert to TRUE
  no_numeric <- c("eval", "echo", "warning")
  for (option in no_numeric) {
    if (is.numeric(options[[option]])) {
      fmt <- "numeric '%s' chunk option not supported by reticulate engine"
      msg <- sprintf(fmt, option)
      warning(msg, call. = FALSE)
      options[[option]] <- TRUE
    }
  }
  
  options
}

eng_python_is_matplotlib_output <- function(value) {

  # extract 'boxed' matplotlib outputs
  if (inherits(value, "python.builtin.list") && length(value) == 1)
    value <- value[[0]]

  # TODO: are there other types we care about?
  inherits(value, "matplotlib.artist.Artist")

}

eng_python_matplotlib_handle_output <- function(captured, last_value, show) {

  value <- py_last_value()

  # bail if no new value was produced by interpreter
  builtins <- import_builtins(convert = TRUE)
  if (builtins$id(last_value) == builtins$id(value))
    return(captured)

  # bail if this isn't matplotlib output
  if (!eng_python_is_matplotlib_output(value))
    return(captured)

  # show plot if requested
  if (show) {
    plt <- import("matplotlib.pyplot", convert = TRUE)
    plt$show()
  }

  # suppress textual output
  ""

}
