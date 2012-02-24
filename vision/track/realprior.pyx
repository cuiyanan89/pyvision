import logging
from vision.reconstruction import pmvs
import numpy
import vision
import matplotlib.pyplot as plt
from vision.reconstruction import plywriter

cimport numpy
from vision cimport annotations

logger = logging.getLogger("vision.track.realcoords")

cdef extern from "math.h":
    float exp(float n)

class ThreeD(object):
    def __init__(self, video, patches, projections):
        self.video = video
        self.patches = patches
        self.projections = projections
        self.built = False
        self.sigma = 1

    def build(self, seeds, forcescore = None):
        cdef double x, y, z
        cdef double normalizer, score 
        cdef double px, py, pn
        cdef annotations.Box seed
        cdef numpy.ndarray[numpy.double_t, ndim=2] matrix

        logger.info("Building 3D model")

        logger.debug("Cleaning seeds")
        useseeds = []
        for seed in seeds:
            if seed.frame in self.projections:
                useseeds.append(seed)
        seeds = useseeds

        logger.info("Using {0} seeds".format(len(seeds)))

        if forcescore is not None:
            for seed in seeds:
                seed.score = forcescore

        if not seeds:
            logger.warning("No seeds")

        logger.debug("Voting in 3-space")
        self.mapping = {}
        cdef double sigma = self.sigma
        for patch in self.patches:
            score = 0
            for seed in seeds:
                matrix = self.projections[seed.frame].matrix
                x, y, z, _ = patch.realcoords
                pn = matrix[2,0]*x + matrix[2,1]*y +matrix[2,2]*z + matrix[2,3]
                if pn < 0:
                    continue
                px = (matrix[0,0]*x + matrix[0,1]*y +matrix[0,2]*z + matrix[0,3]) / pn
                py = (matrix[1,0]*x + matrix[1,1]*y +matrix[1,2]*z + matrix[1,3]) / pn
                if seed.xtl <= px and seed.xbr >= px and seed.ytl <= py and seed.ybr >= py:
                    score += exp(seed.score / sigma)
            if score > 0:
                normalizer += score
                self.mapping[x, y, z] = score
        self.normalizer = normalizer
        self.built = True

        if self.normalizer == 0:
            logger.warning("Normalizer in 3D is 0")

        return self

    def estimate(self):
        if not self.built:
            raise RuntimeError("ThreeD prior must be built first")
        logger.info("Estimating shape")

        cdef double mux, muy, muz, x, y, z, score
        for (x, y, z), score in self.mapping.iteritems():
            mux += x * score
            muy += y * score
            muz += z * score
        mux = mux / self.normalizer
        muy = muy / self.normalizer
        muz = muz / self.normalizer

        print mux, muy, muz

        return self

    def hasprojection(self, frame):
        return frame in self.projections

    def scorelocations(self, frame, int radius = 10):
        cdef numpy.ndarray[numpy.double_t, ndim=2] prob2map
        cdef numpy.ndarray[numpy.double_t, ndim=2] matrix
        cdef int pxi, pxii, pyi, pyii
        cdef double x, y, z
        cdef double normalizer2d, normalizer, prob3d

        videoframe = self.video[frame]
        prob2map = numpy.zeros(videoframe.size)

        if frame not in self.projections:
            logger.warning("Frame {0} cannot project".format(frame))
            return prob2map

        projection = self.projections[frame]
        matrix = projection.matrix
        prob2map = numpy.zeros(videoframe.size)
        width, height = videoframe.size
        points = []
        normalizer2d = 0
        normalizer = self.normalizer
        for (x, y, z), prob3d in self.mapping.iteritems():
            prob3d = prob3d / normalizer
            pn = matrix[2,0]*x + matrix[2,1]*y +matrix[2,2]*z + matrix[2,3]
            if pn < 0:
                continue
            pxi = <int>((matrix[0,0]*x+matrix[0,1]*y+matrix[0,2]*z+matrix[0,3])/pn)
            pyi = <int>((matrix[1,0]*x+matrix[1,1]*y+matrix[1,2]*z+matrix[1,3])/pn)
            for pxii in range(pxi - radius, pxi + radius + 1):
                for pyii in range(pyi - radius, pyi + radius + 1):
                    if pxii < 0 or pyii < 0 or pxii >= width or pyii >= height:
                        continue
                    prob2map[pxii, pyii] += prob3d
                    normalizer2d += prob3d
        if normalizer2d == 0:
            logger.warning("Normalizer for frame {0} is 0".format(frame))
        prob2map /= normalizer2d
        return prob2map

    def scoreall(self, radius = 10):
        for frame in self.projections:
            yield frame, self.scorelocations(frame, radius)