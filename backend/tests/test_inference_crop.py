"""Leaf mask cropping: a short box must not cut the leaf along a straight line, and must not pull in a neighbour."""

import numpy as np

from app.inference import crop_leaf, crop_to_box


def ellipse(shape, cy, cx, ry, rx):
    yy, xx = np.mgrid[: shape[0], : shape[1]]
    return ((yy - cy) / ry) ** 2 + ((xx - cx) / rx) ** 2 <= 1


def test_box_crop_cuts_a_leaf_whose_box_is_too_short():
    leaf = ellipse((200, 200), 100, 100, 80, 50)  # spans rows 20..180
    short_box = np.array([50, 20, 150, 150])  # box stops at row 150
    assert crop_to_box(leaf, short_box)[150:].sum() == 0  # the plain crop loses the bottom of the leaf


def test_leaf_crop_restores_the_cut_side():
    leaf = ellipse((200, 200), 100, 100, 80, 50)  # rows 20..180, cols 50..150
    short_box = np.array([49, 19, 152, 150])  # contains the leaf's width and top, but stops at row 150
    assert not (crop_to_box(leaf, short_box) == leaf).all()
    assert (crop_leaf(leaf, short_box) == leaf).all()  # the whole leaf comes back


def test_leaf_crop_is_the_plain_box_crop_when_nothing_is_cut():
    leaf = ellipse((200, 200), 100, 100, 60, 40)  # rows 40..160, cols 60..140
    box = np.array([55, 35, 146, 166])
    assert (crop_leaf(leaf, box) == crop_to_box(leaf, box)).all()


def test_leaf_crop_does_not_pull_in_a_separate_neighbour():
    leaf = ellipse((300, 200), 100, 100, 80, 50)  # rows 20..180
    neighbour = ellipse((300, 200), 240, 100, 30, 60)  # rows 210..270, not touching the leaf
    mask = leaf | neighbour
    out = crop_leaf(mask, np.array([50, 20, 150, 150]))
    assert out[150:181].any()  # the leaf's own bottom is restored
    assert not out[200:].any()  # the neighbour stays out


def test_leaf_crop_at_the_image_edge():
    leaf = ellipse((200, 200), 150, 100, 80, 50)  # runs off the bottom of the image
    box = np.array([50, 70, 150, 200])  # box ends at the image border: nothing outside to check
    assert (crop_leaf(leaf, box) == crop_to_box(leaf, box)).all()
