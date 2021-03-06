# Everything in this file gets sourced during simInit, and all functions and objects
# are put into the simList. To use objects, use sim$xxx, and are thus globally available
# to all modules. Functions can be used without sim$ as they are namespaced, like functions
# in R packages. If exact location is required, functions will be: sim$<moduleName>$FunctionName
defineModule(sim, list(
  name = "BiomassSpeciesData",
  description = "Download and pre-process proprietary LandWeb data.",
  keywords = c("LandWeb", "LandR"),
  authors = c(
    person(c("Eliot", "J", "B"), "McIntire", email = "eliot.mcintire@canada.ca", role = c("aut", "cre")),
    person(c("Alex", "M."), "Chubaty", email = "achubaty@friresearch.ca", role = c("aut")),
    person("Ceres", "Barros", email = "cbarros@mail.ubc.ca", role = c("aut"))
  ),
  childModules = character(0),
  version = list(SpaDES.core = "0.2.3.9009", BiomassSpeciesData = "0.0.1"),
  spatialExtent = raster::extent(rep(NA_real_, 4)),
  timeframe = as.POSIXlt(c(NA, NA)),
  timeunit = "year",
  citation = list("citation.bib"),
  documentation = list("README.txt", "BiomassSpeciesData.Rmd"),
  reqdPkgs = list("data.table", "googledrive", "gdalUtils", "magrittr", "pryr", "raster", ## TODO: is gdalUtils actually used?
                  "reproducible", "SpaDES.core", "SpaDES.tools",
                  "PredictiveEcology/LandR@development",
                  "PredictiveEcology/pemisc@development"),
  parameters = rbind(
    #defineParameter("paramName", "paramClass", value, min, max, "parameter description"),
    defineParameter("omitNonTreePixels", "logical", TRUE, NA, NA,
                    "If nonTreePixels object supplied, should these pixels be converted to NA in the speciesLayer stack"),
    defineParameter("sppEquivCol", "character", "LandR", NA, NA,
                    "The column in sim$specieEquivalency data.table to use as a naming convention"),
    defineParameter("types", "character", "KNN", NA, NA,
                    "The possible data sources. These must correspond to a function named paste0('prepSpeciesLayers_', type)"),
    defineParameter("vegLeadingProportion", "numeric", 0.8, 0, 1,
                    "a number that define whether a species is leading for a given pixel"),
    defineParameter(".plotInitialTime", "numeric", NA, NA, NA,
                    "This describes the simulation time at which the first plot event should occur"),
    defineParameter(".plotInterval", "numeric", NA, NA, NA,
                    "This describes the simulation time interval between plot events"),
    defineParameter(".saveInitialTime", "numeric", NA, NA, NA,
                    "This describes the simulation time at which the first save event should occur"),
    defineParameter(".saveInterval", "numeric", NA, NA, NA,
                    "This describes the simulation time interval between save events"),
    defineParameter(".useCache", "logical", TRUE, NA, NA,
                    paste("Should this entire module be run with caching activated?",
                          "This is generally intended for data-type modules, where stochasticity and time are not relevant")),
    defineParameter(".useParallel", "numeric", parallel::detectCores(), NA, NA,
                    "Used in reading csv file with fread. Will be passed to data.table::setDTthreads")
  ),
  inputObjects = bind_rows(
    expectsInput("nonTreePixels", "integer",
                 desc = paste("A vector of pixel ids indicating non vegetation pixels,",
                              "which will be converted to NA, if P(sim)$omitNonTreePixels is TRUE"),
                 sourceURL = ""),
    expectsInput("rasterToMatch", "RasterLayer",
                 desc = paste("Raster layer of buffered study area used for cropping, masking and projecting.",
                              "Defaults to the kNN biomass map masked with `studyArea`"),
                 sourceURL = "http://tree.pfc.forestry.ca/kNN-StructureBiomass.tar"),
    expectsInput("rasterToMatchReporting", "RasterLayer",
                 desc = paste("Raster layer of study area used for plotting and reporting only.",
                              "Defaults to the kNN biomass map masked with `studyArea`"),
                 sourceURL = "http://tree.pfc.forestry.ca/kNN-StructureBiomass.tar"),
    expectsInput("speciesLayers", "RasterStack",
                 desc = "biomass percentage raster layers by species in Canada species map",
                 sourceURL = "http://tree.pfc.forestry.ca/kNN-Species.tar"),
    expectsInput("sppColors", "character",
                 desc = paste("A named vector of colors to use for plotting.",
                              "The names must be in sim$speciesEquivalency[[sim$sppEquivCol]],",
                              "and should also contain a color for 'Mixed'"),
                 sourceURL = NA),
    expectsInput("sppEquiv", "data.table",
                 desc = "table of species equivalencies. See LandR::sppEquivalencies_CA.",
                 sourceURL = ""),
    expectsInput("studyArea", "SpatialPolygonsDataFrame",
                 desc =  paste("Multipolygon to use as the study area.",
                               "(studyArea is typically buffered to the actual study area of interest.)",
                               "Defaults to an area in Southwestern Alberta, Canada."),
                 sourceURL = NA),
    expectsInput("studyAreaLarge", "SpatialPolygonsDataFrame",
                 desc = paste("multipolygon (larger area than studyArea) to use for parameter estimation.",
                              "Defaults to an area in Southwestern Alberta, Canada."),
                 sourceURL = NA),
    expectsInput("studyAreaReporting", "SpatialPolygonsDataFrame",
                 desc = paste("multipolygon (typically smaller/unbuffered than studyArea) to use for plotting/reporting.",
                              "Defaults to an area in Southwestern Alberta, Canada."),
                 sourceURL = NA)
  ),
  outputObjects = bind_rows(
    createsOutput("speciesLayers", "RasterStack",
                  desc = "biomass percentage raster layers by species in Canada species map"),
    createsOutput("treed", "data.table",
                  desc = "one logical column for each species, indicating whether there were non-zero values"),
    createsOutput("numTreed", "numeric",
                  desc = "a named vector with number of pixels with non-zero cover values"),
    createsOutput("nonZeroCover", "numeric",
                  desc = "A single value indicating how many pixels have non-zero cover")

  )
))

## event types
#   - type `init` is required for initialiazation

doEvent.BiomassSpeciesData <- function(sim, eventTime, eventType) {
  switch(
    eventType,
    init = {
      sim <- scheduleEvent(sim, P(sim)$.plotInitialTime, "BiomassSpeciesData", "initPlot",
                           eventPriority = 1)

      sim <- biomassDataInit(sim)
    },
    initPlot = {
      devCur <- dev.cur()
      quickPlot::dev(2)
      plotVTM(speciesStack = raster::mask(sim$speciesLayers, sim$studyAreaReporting) %>% stack(),
              vegLeadingProportion = P(sim)$vegLeadingProportion,
              sppEquiv = sim$sppEquiv,
              sppEquivCol = P(sim)$sppEquivCol,
              colors = sim$sppColors,
              title = "Initial Types")
      quickPlot::dev(devCur)

    },
    warning(paste("Undefined event type: '", current(sim)[1, "eventType", with = FALSE],
                  "' in module '", current(sim)[1, "moduleName", with = FALSE], "'", sep = ""))
  )
  return(invisible(sim))
}

### template initialization
biomassDataInit <- function(sim) {
  cacheTags <- c(currentModule(sim), "function:biomassDataInit")
  dPath <- asPath(getOption("reproducible.destinationPath", dataPath(sim)), 1)
  message(currentModule(sim), ": biomassInit() using dataPath '", dPath, "'.")

  if (!exists("speciesLayers", envir = envir(sim), inherits = FALSE))
    sim$speciesLayers <- list()

  for (type in P(sim)$types) {
    fnName <- paste0("prepSpeciesLayers_", type)
    whereIsFnName <- pryr::where(fnName)

    envirName <- attr(whereIsFnName, "name")
    if (is.null(envirName))
      envirName <- whereIsFnName

    message("#############################################")
    message(type, " -- Loading using ", fnName, " located in ", envirName)
    message("#############################################")
    if (!exists(fnName)) {
      stop(fnName, " does not exist. Please make it accessible in a package, as an object, ",
           " or in the .GlobalEnv")
    }

    fn <- get(fnName)
    speciesLayersNew <- Cache(fn,
                              destinationPath = dPath, # this is generic files (preProcess)
                              outputPath = outputPath(sim), # this will be the studyArea-specific files (postProcess)
                              studyArea = sim$studyArea,
                              rasterToMatch = sim$rasterToMatch,
                              sppEquiv = sim$sppEquiv,
                              sppEquivCol = P(sim)$sppEquivCol,
                              userTags = cacheTags)
    sim$speciesLayers <- if (length(sim$speciesLayers) > 0) {
      overlayStacks(highQualityStack = speciesLayersNew,
                    lowQualityStack = sim$speciesLayers,
                    destinationPath = dPath)
    } else {
      speciesLayersNew
    }
    rm(speciesLayersNew)
  }

  ## re-enforce study area mask (merged/summed layers are losing the mask)
  sim$speciesLayers <- raster::mask(sim$speciesLayers, sim$studyArea) %>% stack()

  if (isTRUE(P(sim)$omitNonTreePixels)) {
    message("Setting all speciesLayers[nonTreePixels] to NA")
    sim$speciesLayers[sim$nonTreePixels] <- NA
  }

  sim$speciesLayers <- raster::stack(sim$speciesLayers)

  singular <- length(P(sim)$types) == 1
  message("sim$speciesLayers is from ", paste(P(sim)$types, collapse = ", "),
          " overlaid in that sequence, higher quality last"[!singular])

  message("------------------")
  message("There are ", sum(!is.na(sim$speciesLayers[[1]][])),
          " pixels with trees in them")

  # Calculate number of pixels with species cover
  speciesLayersDT <- as.data.table(sim$speciesLayers[] > 0)
  speciesLayersDT[, pixelId := seq(NROW(speciesLayersDT))]
  sim$treed <- na.omit(speciesLayersDT)
  colNames <- names(sim$treed)[!names(sim$treed) %in% "pixelId"]
  sim$numTreed <- sim$treed[, append(
    lapply(.SD, sum),
    list(total = NROW(sim$treed))), .SDcols = colNames]

  # How many have zero cover
  bb <- speciesLayersDT[, apply(.SD, 1, any), .SDcols = 1:5]
  sim$nonZeroCover <- sum(na.omit(bb))
  message("There are ", sim$nonZeroCover,
          " pixels with non-zero tree cover in them")

  return(invisible(sim))
}

.inputObjects <- function(sim) {
  cacheTags <- c(currentModule(sim), "function:.inputObjects")
  dPath <- asPath(getOption("reproducible.destinationPath", dataPath(sim)), 1)
  message(currentModule(sim), ": using dataPath '", dPath, "'.")

  if (!suppliedElsewhere("studyArea", sim)) {
    message("'studyArea' was not provided by user. Using a polygon in southwestern Alberta, Canada,")

    sim$studyArea <- randomStudyArea(seed = 1234)
  }

  if (!suppliedElsewhere("studyAreaLarge", sim)) {
    message("'studyAreaLarge' was not provided by user. Using the same as 'studyArea'.")
    sim$studyAreaLarge <- sim$studyArea
  }

  if (!suppliedElsewhere("studyAreaReporting", sim)) {
    message("'studyAreaReporting' was not provided by user. Using the same as 'studyArea'.")
    sim$studyAreaReporting <- sim$studyArea
  }

  if (is.null(sim$rasterToMatch)) {
    if (!suppliedElsewhere("rasterToMatch", sim)) {
      message("There is no 'rasterToMatch' supplied; will attempt to use the kNN biomass map")

      biomassMapFilename <- file.path(dPath, "NFI_MODIS250m_kNN_Structure_Biomass_TotalLiveAboveGround_v0.tif")

      biomassMap <- Cache(prepInputs,
                          targetFile = asPath(basename(biomassMapFilename)),
                          archive = asPath(c("kNN-StructureBiomass.tar",
                                             "NFI_MODIS250m_kNN_Structure_Biomass_TotalLiveAboveGround_v0.zip")),
                          url = extractURL("rasterToMatch"),
                          destinationPath = dPath,
                          studyArea = sim$studyAreaLarge,   ## TODO: should this be studyAreaLarge? in RTM below it is...
                          useSAcrs = TRUE,
                          method = "bilinear",
                          datatype = "INT2U",
                          filename2 = TRUE, overwrite = TRUE,
                          userTags = cacheTags)

      sim$rasterToMatch <- biomassMap
      message("  Rasterizing the studyAreaLarge polygon map")
      #TODO: check whether this LandWeb centric stuf is necessary. Does rasterToMatch need FRI? see Issue #10
      # Layers provided by David Andison sometimes have LTHRC, sometimes LTHFC ... chose whichever
      LTHxC <- grep("(LTH.+C)", names(sim$studyAreaLarge), value = TRUE)
      fieldName <- if (length(LTHxC)) {
        LTHxC
      } else {
        if (length(names(sim$studyAreaLarge)) > 1) {   ## study region may be a simple polygon
          names(sim$studyAreaLarge)[1]
        } else NULL
      }

      sim$rasterToMatch <- crop(fasterizeFromSp(sim$studyAreaLarge, sim$rasterToMatch, fieldName),
                                sim$studyAreaLarge)
      sim$rasterToMatch <- Cache(writeRaster, sim$rasterToMatch,
                                 filename = file.path(dataPath(sim), "rasterToMatch.tif"),
                                 datatype = "INT2U", overwrite = TRUE)
    } else {
      stop("rasterToMatch is going to be supplied, but ", currentModule(sim), " requires it ",
           "as part of its .inputObjects. Please make it accessible to ", currentModule(sim),
           " in the .inputObjects by passing it in as an object in simInit(objects = list(rasterToMatch = aRaster)",
           " or in a module that gets loaded prior to ", currentModule(sim))
    }
  }

  if (!suppliedElsewhere("rasterToMatchReporting")) {
    sim$rasterToMatchReporting <- sim$rasterToMatch
  }

  if (!suppliedElsewhere("sppEquiv", sim)) {
    data("sppEquivalencies_CA", package = "LandR", envir = environment())
    sim$sppEquiv <- as.data.table(sppEquivalencies_CA)

    ## By default, Abies_las is renamed to Abies_sp
    sim$sppEquiv[KNN == "Abie_Las", LandR := "Abie_sp"]

    ## add default colors for species used in model
    if (!is.null(sim$sppColors))
      stop("If you provide sppColors, you MUST also provide sppEquiv")
    sim$sppColors <- sppColors(sim$sppEquiv, P(sim)$sppEquivCol,
                               newVals = "Mixed", palette = "Accent")
  }

  return(invisible(sim))
}
