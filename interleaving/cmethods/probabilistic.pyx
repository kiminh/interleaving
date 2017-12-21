# cython: profile=True, boundscheck=False, wraparound=False

from .ranking import ProbabilisticRanking
from .interleaving_method import InterleavingMethod
import numpy as np
cimport numpy as np
import scipy.misc as misc

DOUBLE = np.float64
ctypedef np.float64_t DOUBLE_t
ctypedef np.int8_t BOOL_t
from libcpp.vector cimport vector

class Probabilistic(InterleavingMethod):
    '''
    Probabilistic Interleaving

    Args:
        lists: two lists of document IDs
        max_length: the maximum length of resultant interleaving.
                    If this is None (default), it is set to the minimum length
                    of the given lists.
        sample_num: If this is None (default), an interleaved ranking is
                    generated every time when `interleave` is called.
                    Otherwise, `sample_num` rankings are sampled in the
                    initialization, one of which is returned when `interleave`
                    is called.
        tau: a parameter that determines the probability of documents
             (default: 3.0)
        replace: rankings are sampled with replacement if it is True.
                          Otherwise, they are sampled without replacement,
                          e.g. given two rankings A and B, one of them is
                          sampled first and then another is used.
    '''
    class Softmax(object):

        def __init__(self, tau, ranking):
            self.tau = tau
            self.ranking = ranking
            self.numerators = 1.0 / np.array(range(1, len(ranking)+1)) ** tau
            self.doc_index = {docid: r for r, docid in enumerate(ranking)}
            self.denominator = np.sum(self.numerators)
            self._original_denominator = self.denominator
            self._non_zero_index = set(range(len(self.numerators)))

        def delete(self, docid):
            if docid not in self.doc_index:
                return 0.0
            old_denominator = self.denominator
            idx = self.doc_index[docid]
            numerator = self.numerators[idx]
            self.denominator -= numerator
            self._non_zero_index.remove(idx)
            if not self.denominator > 0:
                self.denominator = 0
            # Returns probability of sampling docid before deletion
            if old_denominator <= 0:
                return 0.0
            else:
                return numerator / old_denominator

        def reset(self):
            self.denominator = self._original_denominator
            self._non_zero_index = set(range(len(self.numerators)))

        def sample(self):
            if self.denominator == 0:
                return None
            p = np.random.rand() * self.denominator
            cum = 0.0
            for i in self._non_zero_index:
                cum += self.numerators[i]
                if cum > p:
                    return self.ranking[i]
            return self.ranking[i]

    class ProbablisticScore(dict):
        __slots__ = ['allocations']
        def __init__(self, *args, **kwargs):
            self.update(*args, **kwargs)

    def __init__(self, lists, max_length=None, sample_num=None,
        tau=3.0, replace=True):
        '''
        lists: two lists of document IDs
        max_length: the maximum length of resultant interleaving.
                    If this is None (default), it is set to the minimum length
                    of the given lists.
        sample_num: If this is None (default), an interleaved ranking is
                    generated every time when `interleave` is called.
                    Otherwise, `sample_num` rankings are sampled in the
                    initialization, one of which is returned when `interleave`
                    is called.
        tau: a parameter that determines the probability of documents
             (default: 3.0)
        replace: rankings are sampled with replacement if it is True.
                          Otherwise, they are sampled without replacement,
                          e.g. given two rankings A and B, one of them is
                          sampled first and then another is used.
        '''
        self._softmaxs = {}
        self._replace = replace
        for i, l in enumerate(lists):
            self._softmaxs[i] = self.Softmax(tau, l)
        super(Probabilistic, self).__init__(lists,
            max_length=max_length, sample_num=sample_num)

    def _sample(self, max_length, lists):
        '''
        Sample a ranking

        max_length: the maximum length of resultant interleaving
        *lists: lists of document IDs

        Return an instance of Ranking
        '''
        ranker_indices = list(range(len(lists)))
        result = ProbabilisticRanking(lists)
        available_rankers = []

        while len(result) < max_length and len(ranker_indices) > 0:
            if len(available_rankers) == 0:
                available_rankers = list(ranker_indices)
                np.random.shuffle(available_rankers)
            if self._replace:
                ranker_idx = np.random.choice(available_rankers)
            else:
                ranker_idx = available_rankers.pop()
            docid = self._softmaxs[ranker_idx].sample()
            if docid is None:
                ranker_indices.remove(ranker_idx)
                available_rankers = list(ranker_indices)
            else:
                result.append(docid)
                for ranker_idx in ranker_indices:
                    if docid in self._softmaxs[ranker_idx].doc_index:
                        self._softmaxs[ranker_idx].delete(docid)

        # reset the state of softmax
        for i in self._softmaxs:
            self._softmaxs[i].reset()

        return result

    @classmethod
    def compute_scores(cls, ranking, clicks, tau=3.0, n=10**4):
        '''
        ranking: an instance of Ranking
        clicks: a list of indices clicked by a user

        Return a list of scores of each ranker.
        '''
        cdef np.ndarray[DOUBLE_t, ndim=1] initial_o, o, o_prime
        cdef np.ndarray[DOUBLE_t, ndim=1] p_log_all, p_all
        cdef np.ndarray[BOOL_t, ndim=2, cast=True] is_pass
        cdef int i, j, k
        cdef float p, threshold
        cdef np.ndarray[DOUBLE_t, ndim=1] P
        cdef vector[int] R_non_zero, R_used
        cdef vector[float] ps, p_primes
        cdef list A, A_prime

        L = ranking
        C = {ranking[index] for index in clicks}
        if len(ranking.lists) == 2:
            # [Hofmann+, CIKM 2011] (Computationally expensive)
            result = cls.ProbablisticScore({0: 0.0, 1: 0.0})
            result.allocations = {}
            for i in range(2 ** len(ranking)):
                a = []
                for d in L:
                    a.append(i % 2)
                    i //= 2
                c = [0, 0]
                R = [cls.Softmax(tau, R_j) for R_j in ranking.lists]
                cum_p = 1.0
                for j, d in zip(a, L):
                    j_alter = (j + 1) % 2
                    if d in C:
                        c[j] += 1
                    cum_p *= R[j].delete(d)
                    R[j_alter].delete(d)
                if c[0] < c[1]:
                    result[1] += cum_p
                elif c[1] < c[0]:
                    result[0] += cum_p
                result.allocations[tuple(a)] = (c, cum_p)
            return result
        if 2 < len(ranking.lists):
            # [Schuth+, SIGIR 2015]
            R = [cls.Softmax(tau, R_j) for R_j in ranking.lists]
            initial_o = np.zeros(len(R), dtype=DOUBLE)
            p = 0.0
            A_prime = [initial_o]
            p_primes = [p]
            threshold = 1 / float(len(R)) * n ** (1 / float(len(L)))
            for d in L:
                # Break if no click
                # Stop when all the clicks are examined.
                if len(C) == 0:
                    break
                d_in_C = d in C
                if d_in_C:
                    C.remove(d)

                # Compute the document probability
                # Only keep non-zero rankers
                P = np.zeros(len(R), dtype=DOUBLE)
                R_non_zero = []
                for j, R_j in enumerate(R):
                    P[j] = R_j.delete(d)
                    if P[j] > 0.0:
                        R_non_zero.push_back(j)
                if len(R_non_zero) == 0:
                    break

                A = A_prime
                A_prime = []
                ps = p_primes
                p_primes = []
                is_pass = np.random.rand(len(A), len(R_non_zero)) <= threshold
                for i in range(len(A)):
                    o = A[i]
                    p = ps[i]
                    # Skip some assignments with certain probability
                    R_used = [R_non_zero[k]
                        for k in range(len(R_non_zero)) if is_pass[i][k]]
                    for j in R_used:
                        p_prime = p + np.log(P[j])
                        o_prime = np.copy(o)
                        if d_in_C:
                            o_prime[j] += 1
                        A_prime.append(o_prime)
                        p_primes.push_back(p_prime)

            o = np.zeros(len(R), dtype=DOUBLE)
            if len(A_prime) > 0:
                # Use logsumexp to avoid over-flow
                p_log_all = np.array(p_primes)
                p_all = np.exp(p_log_all - misc.logsumexp(p_log_all))
                for i in range(len(A_prime)):
                    o_prime = A_prime[i]
                    p_prime = p_all[i]
                    o += o_prime * p_prime
            result = cls.ProbablisticScore({i: o[i] for i in range(len(R))})
            return result
        else:
            raise ValueError('Invalid number of original lists')
